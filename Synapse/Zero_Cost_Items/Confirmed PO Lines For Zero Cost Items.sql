-- Confirmed PO Lines For Zero Cost Items
-- Lines on CONFIRMED POs (purchtable.documentstate = 40) for items whose item-master cost price = $0.
-- Excludes canceled lines (purchstatus 4) and soft-deleted lines (isdeleted = 1). POType flags return orders.
-- Source: D365 Synapse (dataverse_psprod). 7,319 lines / 6,035 POs / 381 items on 2026-10-09 (18 lines on 1 return order).

WITH zero_cost AS (
    SELECT m.itemid, m.price AS ItemCostPrice
    FROM inventtablemodule m
    WHERE m.dataareaid = '1001'
      AND m.moduletype = 0          -- 0 = Inventory (cost price)
      AND m.price = 0
      AND ISNULL(m.IsDelete, 0) = 0
)
SELECT
    pt.purchid                                  AS PurchId,
    CASE pt.purchstatus WHEN 1 THEN 'Open order' WHEN 2 THEN 'Received' WHEN 3 THEN 'Invoiced'
                        WHEN 4 THEN 'Canceled' ELSE CAST(pt.purchstatus AS VARCHAR(10)) END AS POStatus,
    CASE pt.purchasetype WHEN 3 THEN 'Purchase order' WHEN 4 THEN 'Returned order'
                         WHEN 0 THEN 'Journal' ELSE CAST(pt.purchasetype AS VARCHAR(10)) END AS POType,
    'Confirmed'                                 AS ApprovalStatus,
    pt.orderaccount                             AS VendorAccount,
    vp.name                                     AS VendorName,
    pt.itembuyergroupid                         AS BuyerGroup,
    pt.inventlocationid                         AS Warehouse,
    CAST(pt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS POCreatedPST,
    CAST(pl.deliverydate AS DATE)               AS DeliveryDate,
    pl.linenumber                               AS LineNum,
    pl.itemid                                   AS ItemId,
    pl.name                                     AS LineDescription,
    d.inventcolorid                             AS ColorId,
    d.inventsizeid                              AS SizeId,
    CASE pl.purchstatus WHEN 1 THEN 'Open order' WHEN 2 THEN 'Received' WHEN 3 THEN 'Invoiced'
                        ELSE CAST(pl.purchstatus AS VARCHAR(10)) END AS LineStatus,
    pl.qtyordered                               AS QtyOrdered,
    pl.remaininventphysical                     AS QtyOpen,
    pl.purchprice                               AS POUnitPrice,
    pl.lineamount                               AS POLineAmount,
    pl.paclandedcostperunit                     AS LandedCostPerUnit,
    z.ItemCostPrice
FROM purchtable pt
JOIN purchline pl
      ON pl.purchid = pt.purchid AND pl.dataareaid = pt.dataareaid
     AND ISNULL(pl.IsDelete, 0) = 0
     AND pl.isdeleted = 0               -- D365 soft-deleted PO lines
     AND pl.purchstatus <> 4            -- exclude canceled lines
JOIN zero_cost z
      ON z.itemid = pl.itemid
LEFT JOIN inventdim d
      ON d.inventdimid = pl.inventdimid AND d.dataareaid = pl.dataareaid AND ISNULL(d.IsDelete, 0) = 0
LEFT JOIN vendtable v
      ON v.accountnum = pt.orderaccount AND v.dataareaid = '1001' AND ISNULL(v.IsDelete, 0) = 0
LEFT JOIN dirpartytable vp
      ON vp.recid = v.party AND ISNULL(vp.IsDelete, 0) = 0
WHERE pt.dataareaid = '1001'
  AND ISNULL(pt.IsDelete, 0) = 0
  AND pt.documentstate = 40             -- Confirmed
ORDER BY pt.purchid, pl.linenumber;
