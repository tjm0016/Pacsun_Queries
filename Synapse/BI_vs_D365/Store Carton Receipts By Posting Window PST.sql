/*
    Store Carton Receipts By Posting Window (PST)
    --------------------------------------------------------------------------
    Purpose : List DC->store carton-transfer RECEIPTS that posted in D365 within
              a Pacific-time window, at store + SKU + posting-time detail.
              Built for BI-vs-D365 inventory reconciliation: BI recognizes a
              store carton receipt on its own late-evening snapshot clock
              (~11:44 PM PST), so cartons D365 posts after that cut land in the
              next day's BI store on-hand and show up as a one-day variance.

    Source  : D365 Synapse (Dataverse) -- dataverse_psprod...  (DBeaver: D365-Production)
    Notes   :
      - Carton transfers post BOTH legs: an issue out of the 'XXXX-T' transit
        warehouse (negative) and a receipt into the store 'XXXX' (positive).
        The NOT LIKE '%-T' filter keeps only the real-store side.
      - referencecategory = 6  => Carton Transfer (0=SO,3=PO,4=Movement,13=DC-Sync).
      - datephysical is the business/inventory DATE (what the D365 Inventory Value
        Report buckets by); posted_pst is the true modifieddatetime event time
        (what BI buckets by). Both are shown so seam vs cut-time is visible.
      - TIMEZONE GOTCHA: comparing "col AT TIME ZONE ... " (a datetimeoffset)
        against a bare datetime2 literal makes SQL treat the literal as UTC and
        shifts the window 7h. Always CAST(... AS DATETIME2) on both sides.
*/

DECLARE @start_pst DATETIME2 = '2026-08-04 23:30';   -- window start (Pacific)
DECLARE @end_pst   DATETIME2 = '2026-08-05 02:00';   -- window end   (Pacific)

SELECT
    id.inventlocationid                                        AS warehouse,        -- store number
    CONCAT(it.itemid,'-',id.inventcolorid,'-',id.inventsizeid) AS long_sku,
    it.itemid, id.inventcolorid, id.inventsizeid,
    ito.referenceid                                            AS journal_id,       -- INV-* carton journal
    CAST(it.datephysical AS DATE)                              AS datephysical,     -- IVR inventory date
    CAST(it.modifieddatetime AT TIME ZONE 'UTC'
         AT TIME ZONE 'Pacific Standard Time' AS DATETIME2)    AS posted_pst,       -- true post time (BI clock)
    it.qty,
    it.voucher
FROM inventtrans it
JOIN inventdim id
      ON id.inventdimid = it.inventdimid AND id.dataareaid = it.dataareaid
JOIN inventtransorigin ito
      ON ito.recid = it.inventtransorigin AND ito.dataareaid = it.dataareaid
WHERE it.dataareaid = '1001'
  AND ISNULL(it.IsDelete, 0) = 0
  AND it.datephysical > '1900-01-02'          -- physical postings only
  AND ito.referencecategory = 6               -- carton transfers
  AND id.inventlocationid NOT LIKE '%-T'      -- real stores only (drop transit legs)
  AND CAST(it.modifieddatetime AT TIME ZONE 'UTC'
           AT TIME ZONE 'Pacific Standard Time' AS DATETIME2) >= @start_pst
  AND CAST(it.modifieddatetime AT TIME ZONE 'UTC'
           AT TIME ZONE 'Pacific Standard Time' AS DATETIME2) <  @end_pst
ORDER BY posted_pst, warehouse, long_sku;
