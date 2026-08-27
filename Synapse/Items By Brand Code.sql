/*  Items By Brand Code
    Source: D365 Synapse serverless (works against ps-prod or ps-perf).

    Lists every released item carrying each brand code, with variant count and
    current on-hand, so you can pick a test item per brand.

    Brand master  = dbo.suntafbrand  (Brand = suntafbrandvalue, Description =
                    suntafitemattributedesc, Brand code = pacbrandcode)
    Item -> brand = dbo.inventdimcombination.pacbrandid  (variant level; the
                    item-level dbo.inventtable.suntafbrandvalue is populated on
                    only a handful of items, so it is NOT a reliable filter)

    Change the LIKE filter below to target other brands.
*/
WITH v AS (
    SELECT c.pacbrandid COLLATE DATABASE_DEFAULT AS brandval,
           c.itemid     COLLATE DATABASE_DEFAULT AS itemid,
           COUNT(*) AS variants
    FROM dbo.inventdimcombination c
    WHERE ISNULL(c.IsDelete,0) = 0
      AND c.dataareaid = '1001'
      AND c.pacbrandid LIKE '0000000%'          -- the numeric "new" brand block
    GROUP BY c.pacbrandid, c.itemid
),
oh AS (
    SELECT s.itemid COLLATE DATABASE_DEFAULT AS itemid,
           SUM(s.physicalinvent) AS onhand,
           SUM(s.availphysical)  AS avail
    FROM dbo.inventsum s
    WHERE ISNULL(s.IsDelete,0) = 0
      AND s.dataareaid = '1001'
      AND s.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM v)
    GROUP BY s.itemid
)
SELECT b.suntafbrandvalue          AS brand,
       b.suntafitemattributedesc   AS brand_desc,
       b.pacbrandcode              AS brand_code,
       v.itemid,
       t.name                      AS item_name,
       v.variants,
       ISNULL(oh.onhand,0)         AS onhand_qty,
       ISNULL(oh.avail,0)          AS avail_qty
FROM v
JOIN dbo.suntafbrand b
      ON b.suntafbrandvalue COLLATE DATABASE_DEFAULT = v.brandval
     AND b.dataareaid = '1001' AND ISNULL(b.IsDelete,0) = 0
LEFT JOIN dbo.inventtable i
      ON i.itemid COLLATE DATABASE_DEFAULT = v.itemid
     AND i.dataareaid = '1001' AND ISNULL(i.IsDelete,0) = 0
LEFT JOIN dbo.ecoresproducttranslation t
      ON t.product = i.product AND ISNULL(t.IsDelete,0) = 0
LEFT JOIN oh ON oh.itemid = v.itemid
ORDER BY b.suntafbrandvalue, ISNULL(oh.onhand,0) DESC, v.variants DESC, v.itemid;


/*  Companion: which brand codes have NO items at all
    (run on both environments - the empty ones are empty in prod too) */
--WITH b AS (
--    SELECT dataareaid, suntafbrandvalue, suntafitemattributedesc, pacbrandcode
--    FROM dbo.suntafbrand
--    WHERE ISNULL(IsDelete,0)=0 AND dataareaid='1001' AND suntafbrandvalue LIKE '0000000%'
--),
--itm AS (
--    SELECT i.suntafbrandvalue COLLATE DATABASE_DEFAULT AS brandval, COUNT(DISTINCT i.itemid) AS item_cnt
--    FROM dbo.inventtable i
--    WHERE ISNULL(i.IsDelete,0)=0 AND i.dataareaid='1001' AND i.suntafbrandvalue <> ''
--    GROUP BY i.suntafbrandvalue
--),
--idc AS (
--    SELECT c.pacbrandid COLLATE DATABASE_DEFAULT AS brandval,
--           COUNT(DISTINCT c.itemid) AS variant_item_cnt, COUNT(*) AS variant_cnt
--    FROM dbo.inventdimcombination c
--    WHERE ISNULL(c.IsDelete,0)=0 AND c.dataareaid='1001' AND c.pacbrandid <> ''
--    GROUP BY c.pacbrandid
--)
--SELECT b.suntafbrandvalue AS brand, b.suntafitemattributedesc AS descr, b.pacbrandcode AS brandcode,
--       ISNULL(itm.item_cnt,0) AS items_on_inventtable,
--       ISNULL(idc.variant_item_cnt,0) AS items_on_variants,
--       ISNULL(idc.variant_cnt,0) AS variant_rows
--FROM b
--LEFT JOIN itm ON itm.brandval = b.suntafbrandvalue COLLATE DATABASE_DEFAULT
--LEFT JOIN idc ON idc.brandval = b.suntafbrandvalue COLLATE DATABASE_DEFAULT
--ORDER BY b.suntafbrandvalue;
