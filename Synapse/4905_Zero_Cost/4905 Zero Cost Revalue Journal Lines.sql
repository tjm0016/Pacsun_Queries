-- 4905 Zero Cost Revalue Journal Lines
-- Builds the two MOV-DCADJ movement journals that reset under-costed 4905 stock to the confirmed PO cost,
-- in the same shape as Udesh's 10/12/2026 fix (INV-02253604 pull back / INV-02253606 add back):
--   1 PULL BACK : remove the available units at their current average cost (below @MaxUnitCost)
--   2 ADD BACK  : put the same units back at the confirmed PO cost
-- One row per 4905 item + color + size + location. Same LineNumber on both sides.
--
-- Which stock: 4905 cost pools (item + color + size; Active and Lock_Code share one pool) holding units
-- whose average cost is below @MaxUnitCost (set it below), or whose value is zero or negative.
--   0.01 = $0 stock only (pull back totals $0)   |   1.00 = anything under $1 a unit
-- Confirmed PO cost (PO lines received into 4901 only), first found:
--   a) latest confirmed PO line for the same item/color/size with landed cost per unit > 0
--   b) latest confirmed PO for the item with landed cost: SUM(landed total) / SUM(qty)   (same math as ISS-01529)
--   c) latest confirmed PO line for the same item/color/size, FOB (line amount / qty)
-- Pools with none of these are left out (CostSource = 'NO PO COST' rows are not returned).
--
-- Quantity = AVAILABLE physical. Reserved or picked units can't be pulled back; ReservedQty shows any left
-- behind at the old cost, which keeps that pool below the PO cost until they ship.
-- Source: D365 Synapse (dataverse_psprod). Read-only.

DECLARE @MaxUnitCost decimal(10,4) = 0.01;   -- pools averaging below this per unit get revalued

WITH pool AS (            -- 4905 moving-average cost pool per item + color + size
    SELECT s.itemid COLLATE DATABASE_DEFAULT AS ItemId,
           d.inventcolorid COLLATE DATABASE_DEFAULT AS ColorId,
           d.inventsizeid  COLLATE DATABASE_DEFAULT AS SizeId,
           SUM(s.postedqty + s.received - s.deducted) AS PoolQty,
           SUM(s.postedvalue + s.physicalvalue)       AS PoolValue
    FROM inventsum s
    JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = s.inventdimid COLLATE DATABASE_DEFAULT
    WHERE s.dataareaid = '1001' AND ISNULL(s.IsDelete, 0) = 0
      AND d.inventlocationid COLLATE DATABASE_DEFAULT = '4905'
    GROUP BY s.itemid, d.inventcolorid, d.inventsizeid
    HAVING SUM(s.postedqty + s.received - s.deducted) > 0
),
poline AS (               -- confirmed, live PO lines for items that have 4905 stock
    SELECT pl.itemid COLLATE DATABASE_DEFAULT AS ItemId,
           d.inventcolorid COLLATE DATABASE_DEFAULT AS ColorId,
           d.inventsizeid  COLLATE DATABASE_DEFAULT AS SizeId,
           pl.purchid COLLATE DATABASE_DEFAULT AS PurchId,
           pt.createddatetime AS POCreated,
           pl.purchqty, pl.lineamount, pl.paclandedcostperunit, pl.paclandedcosttotal
    FROM purchline pl
    JOIN purchtable pt ON pt.purchid = pl.purchid AND pt.dataareaid = pl.dataareaid
                      AND ISNULL(pt.IsDelete, 0) = 0 AND pt.documentstate = 40 AND pt.purchasetype = 3
    JOIN inventdim d   ON d.inventdimid COLLATE DATABASE_DEFAULT = pl.inventdimid COLLATE DATABASE_DEFAULT
    WHERE pl.dataareaid = '1001' AND ISNULL(pl.IsDelete, 0) = 0 AND pl.isdeleted = 0
      AND pl.purchstatus <> 4 AND pl.purchqty > 0
      AND d.inventlocationid COLLATE DATABASE_DEFAULT = '4901'   -- DC POs only (skips WHSL / dropship ship-tos)
      AND pl.itemid COLLATE DATABASE_DEFAULT IN (SELECT ItemId FROM pool)
),
var_landed AS (           -- a) latest variant line with landed cost
    SELECT ItemId, ColorId, SizeId, PurchId, paclandedcostperunit AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId, ColorId, SizeId ORDER BY POCreated DESC, PurchId DESC) rn
    FROM poline WHERE paclandedcostperunit > 0
),
item_landed AS (          -- b) latest PO for the item with landed cost, ISS-01529 math
    SELECT ItemId, PurchId, SUM(paclandedcosttotal) / SUM(purchqty) AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId ORDER BY MAX(POCreated) DESC, PurchId DESC) rn
    FROM poline GROUP BY ItemId, PurchId HAVING SUM(paclandedcosttotal) > 0
),
var_fob AS (              -- c) latest variant line, FOB
    SELECT ItemId, ColorId, SizeId, PurchId, lineamount / purchqty AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId, ColorId, SizeId ORDER BY POCreated DESC, PurchId DESC) rn
    FROM poline WHERE lineamount > 0
),
target AS (               -- under-costed pools with their new cost
    SELECT p.*,
           ROUND(COALESCE(vl.Cost, il.Cost, vf.Cost), 2) AS NewUnitCost,
           CASE WHEN vl.Cost IS NOT NULL THEN 'PO landed (variant)'
                WHEN il.Cost IS NOT NULL THEN 'PO landed (item)'
                ELSE 'PO FOB (variant)' END AS CostSource,
           COALESCE(vl.PurchId, il.PurchId, vf.PurchId) AS SourcePO
    FROM pool p
    LEFT JOIN var_landed  vl ON vl.ItemId = p.ItemId AND vl.ColorId = p.ColorId AND vl.SizeId = p.SizeId AND vl.rn = 1
    LEFT JOIN item_landed il ON il.ItemId = p.ItemId AND il.rn = 1
    LEFT JOIN var_fob     vf ON vf.ItemId = p.ItemId AND vf.ColorId = p.ColorId AND vf.SizeId = p.SizeId AND vf.rn = 1
    WHERE COALESCE(vl.Cost, il.Cost, vf.Cost) > 0
      AND (p.PoolValue <= 0 OR p.PoolValue / p.PoolQty < @MaxUnitCost)
),
loc AS (                  -- available units per 4905 location inside each target pool
    SELECT s.itemid COLLATE DATABASE_DEFAULT AS ItemId,
           d.inventcolorid COLLATE DATABASE_DEFAULT AS ColorId,
           d.inventsizeid  COLLATE DATABASE_DEFAULT AS SizeId,
           d.inventsiteid  COLLATE DATABASE_DEFAULT AS SiteId,
           d.wmslocationid COLLATE DATABASE_DEFAULT AS LocationId,
           ISNULL(d.inventstatusid, '') COLLATE DATABASE_DEFAULT AS StatusId,
           ISNULL(d.licenseplateid, '') COLLATE DATABASE_DEFAULT AS LicensePlate,
           SUM(s.availphysical)  AS AvailQty,
           SUM(s.physicalinvent - s.availphysical) AS ReservedQty
    FROM inventsum s
    JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = s.inventdimid COLLATE DATABASE_DEFAULT
    WHERE s.dataareaid = '1001' AND ISNULL(s.IsDelete, 0) = 0
      AND d.inventlocationid COLLATE DATABASE_DEFAULT = '4905'
    GROUP BY s.itemid, d.inventcolorid, d.inventsizeid, d.inventsiteid, d.wmslocationid, d.inventstatusid, d.licenseplateid
    HAVING SUM(s.availphysical) > 0 OR SUM(s.physicalinvent - s.availphysical) > 0
),
lines AS (
    SELECT ROW_NUMBER() OVER (ORDER BY t.ItemId, t.ColorId, t.SizeId, l.LocationId, l.StatusId, l.LicensePlate) AS LineNumber,
           t.ItemId, t.ColorId, t.SizeId, l.SiteId, l.LocationId, l.StatusId, l.LicensePlate,
           l.AvailQty, l.ReservedQty,
           CASE WHEN t.PoolValue > 0 THEN ROUND(t.PoolValue / t.PoolQty, 2) ELSE 0 END AS CurrentUnitCost,
           t.NewUnitCost, t.CostSource, t.SourcePO, t.PoolQty, t.PoolValue
    FROM target t
    JOIN loc l ON l.ItemId = t.ItemId AND l.ColorId = t.ColorId AND l.SizeId = t.SizeId
    WHERE l.AvailQty > 0
)
SELECT '1 PULL BACK' AS JournalSide,
       'Pull back $0 cost items from 4905' AS JournalDescription,
       LineNumber, ItemId AS ItemNumber, ColorId AS Color, SizeId AS Size, SiteId AS Site, '4905' AS Warehouse,
       LocationId AS Location, StatusId AS InventoryStatus, LicensePlate,
       -AvailQty AS Quantity, CurrentUnitCost AS UnitCost, ROUND(-AvailQty * CurrentUnitCost, 2) AS CostAmount,
       CurrentUnitCost, NewUnitCost, CostSource, SourcePO, PoolQty, PoolValue, ReservedQty
FROM lines
UNION ALL
SELECT '2 ADD BACK',
       'Add cost 4905 for $0 cost transactions',
       LineNumber, ItemId, ColorId, SizeId, SiteId, '4905',
       LocationId, StatusId, LicensePlate,
       AvailQty, NewUnitCost, ROUND(AvailQty * NewUnitCost, 2),
       CurrentUnitCost, NewUnitCost, CostSource, SourcePO, PoolQty, PoolValue, ReservedQty
FROM lines
ORDER BY JournalSide, LineNumber;
