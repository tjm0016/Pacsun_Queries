/* ============================================================================
   D365 Color Usage - which EcoResColor codes are used by active items
   Source : Synapse serverless (d365-synapse-ps-prod-ondemand / dataverse_psprod)
   Active : released variant (inventdimcombination) with product lifecycle
            state = ACTIVE
   Output : one row per color in EcoResColor, Status = USED / NOT USED
   ============================================================================ */
WITH used AS (
    SELECT  id.inventcolorid COLLATE DATABASE_DEFAULT              AS colorid,
            COUNT(DISTINCT idc.itemid)                             AS item_count,
            COUNT(*)                                               AS variant_count,
            SUM(CASE WHEN idc.paclastsalesdate >= DATEADD(month, -12, GETUTCDATE())
                     THEN 1 ELSE 0 END)                            AS variants_sold_last_12m,
            MAX(CASE WHEN idc.paclastsalesdate > '1901-01-01'
                     THEN idc.paclastsalesdate END)                AS last_sale_date
    FROM    inventdimcombination idc
    JOIN    inventdim id
            ON  id.inventdimid = idc.inventdimid
            AND id.dataareaid  = idc.dataareaid
            AND ISNULL(id.IsDelete, 0) = 0
    WHERE   idc.dataareaid = '1001'
      AND   ISNULL(idc.IsDelete, 0) = 0
      AND   UPPER(idc.productlifecyclestateid) = 'ACTIVE'
    GROUP BY id.inventcolorid COLLATE DATABASE_DEFAULT
)
SELECT  c.name COLLATE DATABASE_DEFAULT                        AS color_id,
        c.pacdescription                                       AS color_description,
        CASE WHEN u.colorid IS NULL THEN 'NOT USED' ELSE 'USED' END AS status,
        ISNULL(u.item_count, 0)                                AS item_count,
        ISNULL(u.variant_count, 0)                             AS variant_count,
        ISNULL(u.variants_sold_last_12m, 0)                    AS variants_sold_last_12m,
        CAST(u.last_sale_date AS DATE)                         AS last_sale_date
FROM    ecorescolor c
LEFT JOIN used u
        ON u.colorid = c.name COLLATE DATABASE_DEFAULT
WHERE   ISNULL(c.IsDelete, 0) = 0
ORDER BY status DESC, color_id;   -- USED first, then NOT USED
