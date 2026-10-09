-- Items With Zero Item Master Cost
-- Released products whose item-master cost price (InventTableModule ModuleType 0 .Price) = $0.
-- Source: D365 Synapse (dataverse_psprod). 873 items on 2026-10-09 (868 earlier the same day).

SELECT
    it.itemid                                   AS ItemId,
    COALESCE(ept.name, it.namealias)            AS ProductName,
    it.pacstylenum                              AS StyleNum,
    it.pacvendorstyle                           AS VendorStyle,
    it.itembuyergroupid                         AS BuyerGroup,
    it.primaryvendorid                          AS PrimaryVendor,
    vp.name                                     AS PrimaryVendorName,
    it.productlifecyclestateid                  AS LifecycleState,
    m.price                                     AS ItemCostPrice,
    m.unitid                                    AS CostUnit,
    CAST(it.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS ItemCreatedPST,
    it.createdby                                AS ItemCreatedBy,
    CAST(m.modifieddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS CostLastModifiedPST,
    m.modifiedby                                AS CostLastModifiedBy
FROM inventtablemodule m
JOIN inventtable it
      ON it.itemid = m.itemid AND it.dataareaid = m.dataareaid AND ISNULL(it.IsDelete, 0) = 0
LEFT JOIN ecoresproducttranslation ept
      ON ept.product = it.product AND ept.languageid = 'en-us' AND ISNULL(ept.IsDelete, 0) = 0
LEFT JOIN vendtable v
      ON v.accountnum = it.primaryvendorid AND v.dataareaid = '1001' AND ISNULL(v.IsDelete, 0) = 0
LEFT JOIN dirpartytable vp
      ON vp.recid = v.party AND ISNULL(vp.IsDelete, 0) = 0
WHERE m.dataareaid = '1001'
  AND m.moduletype = 0          -- 0 = Inventory (cost), 1 = Purchase, 2 = Sales
  AND m.price = 0
  AND ISNULL(m.IsDelete, 0) = 0
ORDER BY it.itemid;
