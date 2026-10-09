-- Candidate Costs For Zero Cost Items
-- One row per item whose item-master cost price (InventTableModule ModuleType 0 .Price) = $0, with every
-- available cost source side by side, a recommended cost, and the likely reason the cost was never set.
-- ISS-01529 (in prod with the 6/8/2026 release) sets the item cost on PO confirmation to
--   SUM(purchline.pacLandedCostTotal) / SUM(purchline.PurchQty) for that PO; the last confirmation wins.
-- Recommended = PO landed cost > moving avg (4901, then chain) > PO unit price > variant purch price.
-- No purchase trade agreements (pricedisctable relation 0) exist, so they are not a source.
-- Source: D365 Synapse (dataverse_psprod).
WITH zero_cost AS (
    SELECT m.itemid
    FROM inventtablemodule m
    WHERE m.dataareaid = '1001' AND m.moduletype = 0 AND m.price = 0 AND ISNULL(m.IsDelete, 0) = 0
),
po AS (   -- one row per item per confirmed PO, same math as ISS-01529
    SELECT pl.itemid, pt.purchid, pt.itembuyergroupid, pt.createddatetime,
           SUM(pl.purchqty)            AS qty,
           SUM(pl.paclandedcosttotal)  AS landed_total,
           SUM(pl.lineamount)          AS line_amount
    FROM purchtable pt
    JOIN purchline pl
          ON pl.purchid = pt.purchid AND pl.dataareaid = pt.dataareaid
         AND ISNULL(pl.IsDelete, 0) = 0 AND pl.isdeleted = 0 AND pl.purchstatus <> 4
    WHERE pt.dataareaid = '1001' AND ISNULL(pt.IsDelete, 0) = 0
      AND pt.documentstate = 40          -- Confirmed
      AND pl.itemid IN (SELECT itemid FROM zero_cost)
    GROUP BY pl.itemid, pt.purchid, pt.itembuyergroupid, pt.createddatetime
    HAVING SUM(pl.purchqty) > 0
),
po_ranked AS (
    SELECT po.*,
           ROW_NUMBER() OVER (PARTITION BY itemid ORDER BY createddatetime DESC, purchid DESC) AS rn_latest,
           ROW_NUMBER() OVER (PARTITION BY itemid ORDER BY CASE WHEN landed_total > 0 THEN 0 ELSE 1 END,
                                                           createddatetime DESC, purchid DESC) AS rn_landed,
           COUNT(*)          OVER (PARTITION BY itemid) AS po_count,
           SUM(qty)          OVER (PARTITION BY itemid) AS all_qty,
           SUM(landed_total) OVER (PARTITION BY itemid) AS all_landed
    FROM po
),
po_item AS (
    SELECT itemid,
           MAX(po_count)                                                                 AS ConfirmedPOs,
           MAX(CASE WHEN rn_latest = 1 THEN purchid END)                                 AS LatestPO,
           MAX(CASE WHEN rn_latest = 1 THEN createddatetime END)                         AS LatestPOCreatedUTC,
           MAX(CASE WHEN rn_latest = 1 THEN itembuyergroupid END)                        AS LatestPOBuyerGroup,
           MAX(CASE WHEN rn_latest = 1 THEN landed_total / qty END)                      AS LatestPOLandedCost,
           MAX(CASE WHEN rn_latest = 1 THEN line_amount / qty END)                       AS LatestPOUnitPrice,
           MAX(CASE WHEN rn_landed = 1 AND landed_total > 0 THEN purchid END)            AS LatestLandedPO,
           MAX(CASE WHEN rn_landed = 1 AND landed_total > 0 THEN landed_total / qty END) AS LatestLandedPOCost,
           MAX(CASE WHEN all_qty > 0 THEN all_landed / all_qty END)                      AS AllPOsAvgLandedCost
    FROM po_ranked
    GROUP BY itemid
),
mac AS (  -- moving-average cost from current on-hand: (posted + physical-only value) / qty
    SELECT s.itemid,
           SUM(CASE WHEN s.inventlocationid = '4901' THEN s.postedqty + s.received - s.deducted ELSE 0 END) AS Qty4901,
           SUM(CASE WHEN s.inventlocationid = '4901' THEN s.postedvalue + s.physicalvalue ELSE 0 END)       AS Value4901,
           SUM(s.postedqty + s.received - s.deducted)                                                        AS QtyChain,
           SUM(s.postedvalue + s.physicalvalue)                                                              AS ValueChain
    FROM inventsum s
    WHERE s.dataareaid = '1001' AND ISNULL(s.IsDelete, 0) = 0
      AND s.itemid IN (SELECT itemid FROM zero_cost)
    GROUP BY s.itemid
),
variant AS (  -- variant-level purchase price from the item feed (FOB, no duty/freight)
    SELECT idc.itemid,
           MIN(idc.pacpurchprice) AS VariantPurchPriceMin,
           MAX(idc.pacpurchprice) AS VariantPurchPriceMax,
           AVG(idc.pacpurchprice) AS VariantPurchPriceAvg
    FROM inventdimcombination idc
    WHERE idc.dataareaid = '1001' AND ISNULL(idc.IsDelete, 0) = 0 AND idc.pacpurchprice > 0
      AND idc.itemid IN (SELECT itemid FROM zero_cost)
    GROUP BY idc.itemid
),
item AS (
    SELECT z.itemid AS zitemid, p.*,
           m.Qty4901, m.Value4901, m.QtyChain, m.ValueChain,
           CASE WHEN m.Qty4901  > 0 AND m.Value4901  > 0 THEN m.Value4901  / m.Qty4901  END AS MAC4901,
           CASE WHEN m.QtyChain > 0 AND m.ValueChain > 0 THEN m.ValueChain / m.QtyChain END AS MACChain,
           v.VariantPurchPriceMin, v.VariantPurchPriceMax, v.VariantPurchPriceAvg
    FROM zero_cost z
    LEFT JOIN po_item p ON p.itemid = z.itemid
    LEFT JOIN mac     m ON m.itemid = z.itemid
    LEFT JOIN variant v ON v.itemid = z.itemid
)
SELECT
    i.zitemid                                   AS ItemId,
    COALESCE(ept.name, it.namealias)            AS ProductName,
    it.pacvendorstyle                           AS VendorStyle,
    it.primaryvendorid                          AS PrimaryVendor,
    CASE
        WHEN i.LatestLandedPOCost > 0   THEN i.LatestLandedPOCost
        WHEN i.MAC4901 > 0              THEN i.MAC4901
        WHEN i.MACChain > 0             THEN i.MACChain
        WHEN i.LatestPOUnitPrice > 0    THEN i.LatestPOUnitPrice
        WHEN i.VariantPurchPriceAvg > 0 THEN i.VariantPurchPriceAvg
    END                                         AS RecommendedCost,
    CASE
        WHEN i.LatestLandedPOCost > 0   THEN 'PO landed cost'
        WHEN i.MAC4901 > 0              THEN 'Moving avg cost - 4901'
        WHEN i.MACChain > 0             THEN 'Moving avg cost - chain'
        WHEN i.LatestPOUnitPrice > 0    THEN 'PO unit price (FOB, no landed)'
        WHEN i.VariantPurchPriceAvg > 0 THEN 'Variant purchase price (FOB)'
        ELSE 'No cost source'
    END                                         AS RecommendedSource,
    CASE
        WHEN i.LatestPO IS NULL                  THEN 'Never on a confirmed PO'
        WHEN i.LatestPOCreatedUTC < '2026-06-09' THEN 'Last PO created before cost-on-confirm went live (6/8/2026)'
        WHEN ISNULL(i.LatestPOLandedCost, 0) = 0 AND i.LatestPOBuyerGroup = 'DROPSHIP'
                                                 THEN 'Latest PO is DROPSHIP - dropship POs carry $0 landed cost'
        WHEN ISNULL(i.LatestPOLandedCost, 0) = 0 THEN 'Latest PO has $0 landed cost'
        ELSE 'Latest PO has landed cost but item cost still $0'
    END                                         AS LikelyReason,
    i.ConfirmedPOs,
    i.LatestPO,
    CAST(i.LatestPOCreatedUTC AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS LatestPOCreatedPST,
    i.LatestPOBuyerGroup,
    i.LatestPOLandedCost,
    i.LatestPOUnitPrice,
    i.LatestLandedPO,
    i.LatestLandedPOCost,
    i.AllPOsAvgLandedCost,
    i.MAC4901,
    i.Qty4901                                   AS OnHand4901,
    i.MACChain,
    i.QtyChain                                  AS OnHandChain,
    i.ValueChain                                AS OnHandValueChain,
    i.VariantPurchPriceMin,
    i.VariantPurchPriceMax,
    i.VariantPurchPriceAvg
FROM item i
JOIN inventtable it
      ON it.itemid = i.zitemid AND it.dataareaid = '1001' AND ISNULL(it.IsDelete, 0) = 0
LEFT JOIN ecoresproducttranslation ept
      ON ept.product = it.product AND ept.languageid = 'en-us' AND ISNULL(ept.IsDelete, 0) = 0
ORDER BY i.zitemid;
