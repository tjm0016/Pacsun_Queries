-- 4905 Stock Under Half Of PO Cost
-- Report (no journal lines): 4905 stock whose moving-average cost is at or below @Ratio x its most recent
-- confirmed PO cost. One row per item + color + size (Active and Lock_Code share one cost pool).
--
-- Most recent confirmed PO cost (PO lines received into 4901 only), first found:
--   a) latest confirmed PO line for the same item/color/size with landed cost per unit > 0
--   b) latest confirmed PO for the item with landed cost: SUM(landed total) / SUM(qty)   (same math as ISS-01529)
--   c) latest confirmed PO line for the same item/color/size, FOB (line amount / qty)
-- Sizes with none of these are left out.
-- ValueGap = what the stock would be worth at the PO cost minus what it is worth now.
-- Source: D365 Synapse (dataverse_psprod). Read-only.

DECLARE @Ratio decimal(5,2) = 0.50;   -- 0.50 = at or below half of the PO cost

WITH pool AS (            -- 4905 moving-average cost pool per item + color + size
    SELECT s.itemid COLLATE DATABASE_DEFAULT AS ItemId,
           d.inventcolorid COLLATE DATABASE_DEFAULT AS ColorId,
           d.inventsizeid  COLLATE DATABASE_DEFAULT AS SizeId,
           SUM(s.postedqty + s.received - s.deducted) AS OnHandQty,
           SUM(s.postedvalue + s.physicalvalue)       AS OnHandValue
    FROM inventsum s
    JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = s.inventdimid COLLATE DATABASE_DEFAULT
    WHERE s.dataareaid = '1001' AND ISNULL(s.IsDelete, 0) = 0
      AND d.inventlocationid COLLATE DATABASE_DEFAULT = '4905'
    GROUP BY s.itemid, d.inventcolorid, d.inventsizeid
    HAVING SUM(s.postedqty + s.received - s.deducted) > 0
),
poline AS (               -- confirmed, live 4901 PO lines for items that have 4905 stock
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
      AND d.inventlocationid COLLATE DATABASE_DEFAULT = '4901'
      AND pl.itemid COLLATE DATABASE_DEFAULT IN (SELECT ItemId FROM pool)
),
var_landed AS (
    SELECT ItemId, ColorId, SizeId, PurchId, POCreated, paclandedcostperunit AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId, ColorId, SizeId ORDER BY POCreated DESC, PurchId DESC) rn
    FROM poline WHERE paclandedcostperunit > 0
),
item_landed AS (
    SELECT ItemId, PurchId, MAX(POCreated) AS POCreated, SUM(paclandedcosttotal) / SUM(purchqty) AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId ORDER BY MAX(POCreated) DESC, PurchId DESC) rn
    FROM poline GROUP BY ItemId, PurchId HAVING SUM(paclandedcosttotal) > 0
),
var_fob AS (
    SELECT ItemId, ColorId, SizeId, PurchId, POCreated, lineamount / purchqty AS Cost,
           ROW_NUMBER() OVER (PARTITION BY ItemId, ColorId, SizeId ORDER BY POCreated DESC, PurchId DESC) rn
    FROM poline WHERE lineamount > 0
),
priced AS (
    SELECT p.*,
           COALESCE(vl.Cost, il.Cost, vf.Cost) AS POUnitCost,
           CASE WHEN vl.Cost IS NOT NULL THEN 'PO landed (variant)'
                WHEN il.Cost IS NOT NULL THEN 'PO landed (item)'
                ELSE 'PO FOB (variant)' END AS CostSource,
           COALESCE(vl.PurchId, il.PurchId, vf.PurchId) AS SourcePO,
           COALESCE(vl.POCreated, il.POCreated, vf.POCreated) AS SourcePOCreated
    FROM pool p
    LEFT JOIN var_landed  vl ON vl.ItemId = p.ItemId AND vl.ColorId = p.ColorId AND vl.SizeId = p.SizeId AND vl.rn = 1
    LEFT JOIN item_landed il ON il.ItemId = p.ItemId AND il.rn = 1
    LEFT JOIN var_fob     vf ON vf.ItemId = p.ItemId AND vf.ColorId = p.ColorId AND vf.SizeId = p.SizeId AND vf.rn = 1
    WHERE COALESCE(vl.Cost, il.Cost, vf.Cost) > 0
)
SELECT ItemId AS ItemNumber, ColorId AS Color, SizeId AS Size,
       OnHandQty,
       ROUND(OnHandValue, 2)                                  AS OnHandValue,
       ROUND(OnHandValue / OnHandQty, 4)                      AS UnitCost4905,
       ROUND(POUnitCost, 4)                                   AS POUnitCost,
       ROUND(100.0 * (OnHandValue / OnHandQty) / POUnitCost, 1) AS PctOfPOCost,
       ROUND(OnHandQty * POUnitCost - OnHandValue, 2)        AS ValueGap,
       CostSource, SourcePO,
       CAST(SourcePOCreated AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS date) AS SourcePOCreatedPST
FROM priced
WHERE OnHandValue / OnHandQty <= @Ratio * POUnitCost
ORDER BY ValueGap DESC;
