/*
    Item classes that have ACTIVE products but no row in pacFreightGuidance.

    Class source        : inventtable.suntafclassvalue  (this is the exact field the X++ lookup
                          pacFreightGuidance::findSpecificCharges() is fed from
                          pacApplyLandFactorEstimatesService.retrieveFreightGuidance)
    Active definition   : UPPER(inventtable.productlifecyclestateid) = 'ACTIVE'
    Company             : 1001

    Notes / traps
      - pacfreightguidance holds 14,273 rows with a BLANK dataareaid and NULL itemclass. They are
        not company data. Always filter dataareaid='1001' or the distinct-class count is wrong.
      - itemclass = '' is a deliberate WILDCARD in findSpecificCharges (ItemClass == _itemClass
        OR ItemClass == ''), ordered ItemClass DESC so a specific class wins. A class missing here
        does NOT error - it falls through to the 24 class-agnostic rows.
      - Every class-specific row is DlvTerm='FOB': 12 origin ports x (1 AIR_FRT + 2 OCEAN_FRT modes)
        = exactly 36 rows per class, uniform across all 198 covered classes.
*/
WITH items AS (
    SELECT it.suntafclassvalue AS cls,
           it.itemid,
           CASE WHEN UPPER(it.productlifecyclestateid) = 'ACTIVE' THEN 1 ELSE 0 END AS is_active
    FROM dbo.inventtable it
    WHERE it.dataareaid = '1001'
      AND it.suntafclassvalue <> ''
),
agg AS (
    SELECT cls, SUM(is_active) AS items_active, COUNT(*) AS items_all
    FROM items
    GROUP BY cls
),
po AS (   -- purchasing activity, trailing 12 months, to separate live classes from dead ones
    SELECT i.cls,
           COUNT(DISTINCT pl.purchid) AS po_count_12mo,
           COUNT(*)                   AS po_lines_12mo,
           MAX(pl.createddatetime)    AS last_po_line
    FROM dbo.purchline pl
    JOIN items i ON i.itemid = pl.itemid
    WHERE pl.dataareaid = '1001'
      AND pl.createddatetime >= DATEADD(month, -12, CAST(GETUTCDATE() AS date))
    GROUP BY i.cls
)
SELECT a.cls                                                    AS ItemClass,
       ISNULL(sc.suntafitemattributedesc, '(not in suntafclass)') AS ClassName,
       a.items_active                                           AS ActiveItems,
       a.items_all                                              AS AllItems,
       ISNULL(p.po_count_12mo, 0)                               AS POs12Mo,
       ISNULL(p.po_lines_12mo, 0)                               AS POLines12Mo,
       CONVERT(varchar(10), p.last_po_line, 120)                AS LastPOLine
FROM agg a
LEFT JOIN dbo.suntafclass sc
       ON sc.suntafclassvalue = a.cls
      AND sc.dataareaid = '1001'
LEFT JOIN po p
       ON p.cls = a.cls
WHERE a.items_active > 0
  AND NOT EXISTS (SELECT 1
                  FROM dbo.pacfreightguidance g
                  WHERE g.dataareaid = '1001'
                    AND g.itemclass  = a.cls)
ORDER BY ISNULL(p.po_lines_12mo, 0) DESC, a.items_active DESC;
