/*
  Invent Trans By Item
  ---------------------------------------------------------------------------
  Every inventtrans row for one item, with the source document / journal and a
  running quantity, value and moving-average cost per warehouse + color + size
  (the D365 cost pool). Use it to find the exact transaction where an item's
  cost went wrong (e.g. a SKU sitting at $0.00 or $0.01 at 4905).

  Connection: Synapse "D365-Production" (dataverse_psprod_...).

  Parameters: set @ItemId. Leave @Warehouse / @Color / @Size NULL for all.

  Notes
  - Running columns only count physical moves (receipt status 1-2 / issue
    status 1-2). Ordered / on-order rows are listed but don't move the balance.
  - net_cost = costamountposted + costamountadjustment. A non-zero adjustment
    on a receipt means D365 moved the cost difference to 520000 "Price
    difference for moving average" (backdated receipt into the pool).
  - Order is datephysical, then journal posted time, then recid. Within one day
    that order is approximate; end-of-day balances are reliable.
  - The final running_qty / running_value per pool should equal inventsum
    (postedqty / postedvalue + physicalvalue).
  - Sort by seq if your client shows rows out of order (Synapse serverless
    can return window-function results unordered).
  - All datetimes are UTC.
*/
DECLARE @ItemId    varchar(30) = '0133-48426-0039';
DECLARE @Warehouse varchar(20) = '4905';    -- NULL = all warehouses
DECLARE @Color     varchar(20) = '001';     -- NULL = all colors
DECLARE @Size      varchar(20) = '9300';    -- NULL = all sizes

SELECT
    ROW_NUMBER() OVER (ORDER BY t.inventlocationid, t.inventcolorid, t.inventsizeid,
                       t.datephysical, t.journal_posted_utc, t.recid)   AS seq,
    t.itemid,
    t.inventlocationid                      AS warehouse,
    t.inventcolorid                         AS color,
    t.inventsizeid                          AS size,
    t.wmslocationid,
    t.datephysical,
    t.datefinancial,
    t.source,
    t.referenceid,
    t.journal_desc,
    t.journal_posted_utc,
    t.journal_created_by,
    t.receipt_status,
    t.issue_status,
    t.qty,
    t.costamountposted,
    t.costamountadjustment,
    t.costamountphysical,
    t.net_cost,
    CASE WHEN t.qty <> 0 THEN t.net_cost / t.qty END                    AS unit_cost,
    t.journal_line_costprice,
    SUM(t.phys_qty)  OVER (PARTITION BY t.inventlocationid, t.inventcolorid, t.inventsizeid
                           ORDER BY t.datephysical, t.journal_posted_utc, t.recid
                           ROWS UNBOUNDED PRECEDING)                    AS running_qty,
    SUM(t.phys_cost) OVER (PARTITION BY t.inventlocationid, t.inventcolorid, t.inventsizeid
                           ORDER BY t.datephysical, t.journal_posted_utc, t.recid
                           ROWS UNBOUNDED PRECEDING)                    AS running_value,
    SUM(t.phys_cost) OVER (PARTITION BY t.inventlocationid, t.inventcolorid, t.inventsizeid
                           ORDER BY t.datephysical, t.journal_posted_utc, t.recid
                           ROWS UNBOUNDED PRECEDING)
      / NULLIF(SUM(t.phys_qty) OVER (PARTITION BY t.inventlocationid, t.inventcolorid, t.inventsizeid
                           ORDER BY t.datephysical, t.journal_posted_utc, t.recid
                           ROWS UNBOUNDED PRECEDING), 0)                AS running_avg_cost,
    t.voucher,
    t.voucherphysical,
    t.inventtransid,
    t.recid
FROM (
    SELECT
        it.itemid,
        d.inventlocationid, d.inventcolorid, d.inventsizeid, d.wmslocationid,
        it.datephysical, it.datefinancial,
        CASE
            WHEN ij.journalnameid IS NOT NULL THEN ij.journalnameid
            WHEN o.referencecategory = 0  THEN 'Sales order'
            WHEN o.referencecategory = 3  THEN 'Purchase order'
            WHEN o.referencecategory = 6  THEN 'Transfer'
            WHEN o.referencecategory = 21 THEN 'Transfer order shipment'
            WHEN o.referencecategory = 22 THEN 'Transfer order receive'
            ELSE CONCAT('Ref category ', o.referencecategory)
        END                                                         AS source,
        o.referenceid,
        o.inventtransid,
        ij.description                                              AS journal_desc,
        ij.posteddatetime                                           AS journal_posted_utc,
        ij.createdby                                                AS journal_created_by,
        CASE it.statusreceipt WHEN 1 THEN 'Purchased' WHEN 2 THEN 'Received' WHEN 3 THEN 'Registered'
             WHEN 4 THEN 'Arrived' WHEN 5 THEN 'Ordered' WHEN 6 THEN 'Quotation' END       AS receipt_status,
        CASE it.statusissue WHEN 1 THEN 'Sold' WHEN 2 THEN 'Deducted' WHEN 3 THEN 'Picked'
             WHEN 4 THEN 'Reserved physical' WHEN 5 THEN 'Reserved ordered' WHEN 6 THEN 'On order'
             WHEN 7 THEN 'Quotation issue' END                                            AS issue_status,
        it.qty,
        it.costamountposted,
        it.costamountadjustment,
        it.costamountphysical,
        ISNULL(it.costamountposted, 0) + ISNULL(it.costamountadjustment, 0)              AS net_cost,
        ijt.costprice                                               AS journal_line_costprice,
        CASE WHEN it.statusreceipt IN (1, 2) OR it.statusissue IN (1, 2)
             THEN it.qty ELSE 0 END                                 AS phys_qty,
        CASE WHEN it.statusreceipt = 1 OR it.statusissue = 1
                  THEN ISNULL(it.costamountposted, 0) + ISNULL(it.costamountadjustment, 0)
             WHEN it.statusreceipt = 2 OR it.statusissue = 2
                  THEN ISNULL(it.costamountphysical, 0)
             ELSE 0 END                                             AS phys_cost,
        it.voucher,
        it.voucherphysical,
        it.recid
    FROM inventtrans it
    JOIN inventdim d
      ON d.inventdimid = it.inventdimid AND d.dataareaid = it.dataareaid
    JOIN inventtransorigin o
      ON o.recid = it.inventtransorigin
    LEFT JOIN inventjournaltable ij
      ON ij.journalid = o.referenceid AND ij.dataareaid = it.dataareaid
    LEFT JOIN inventjournaltrans ijt
      ON ijt.inventtransid = o.inventtransid AND ijt.dataareaid = it.dataareaid
    WHERE it.dataareaid = '1001'
      AND it.itemid = @ItemId
      AND (@Warehouse IS NULL OR d.inventlocationid = @Warehouse)
      AND (@Color     IS NULL OR d.inventcolorid    = @Color)
      AND (@Size      IS NULL OR d.inventsizeid     = @Size)
      AND ISNULL(it.IsDelete, 0) = 0
) t
ORDER BY seq;
