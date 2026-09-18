/* UPC Barcode Validation
   Validates WM-format SKUs (itemid--color-size, e.g. 0656-61047-0027--075-9900) and their UPCs against:
     - inventitembarcode       D365 barcode master (which SKU owns the UPC; which UPC the SKU carries)
     - inventdimcombination    variant exists + retailvariantid
     - pacwmbarcodexrefmessage WM Barcode XRef outbound (INT-00372); history only starts 2026-04-07, so
                               variants migrated before go-live show 0 rows even though WM has them
     - pacsfccproductcatalogvariants  SFCC ecom catalog (0 rows = not listed online, not an error)
   Paste the list into the inp CTE (Synapse serverless has no VALUES CTE - keep the UNION ALL form).
   Status: MATCH | UPC ON DIFFERENT SKU | SKU HAS DIFFERENT UPC | NOT FOUND */
WITH inp AS (
    SELECT '0656-61047-0027--075-9900' AS sku, '198437895686' AS upc
    UNION ALL SELECT '0723-46868-0004--066-9200', '198437931964'
    UNION ALL SELECT '0771-47163-0002--001-9300', '198437951962'
    UNION ALL SELECT '0641-51481-0173--030-9900', '199831797521'
    UNION ALL SELECT '0860-60489-0178--326-2390', '199916057656'
    UNION ALL SELECT '0777-46868-0001--010-9400', '199916253478'
    UNION ALL SELECT '0777-46868-0004--066-9200', '199916253522'
    UNION ALL SELECT '0703-48426-0136--001-9300', '199916255984'
    UNION ALL SELECT '0703-48426-0136--010-9400', '199916255991'
    UNION ALL SELECT '0777-46868-0001--010-9200', '199916420351'
    UNION ALL SELECT '0777-46868-0004--066-9300', '199916420405'
    UNION ALL SELECT '0703-48426-0136--001-9400', '199916422881'
    UNION ALL SELECT '0777-46868-0001--010-9100', '199916503412'
    UNION ALL SELECT '0777-46868-0002--010-9400', '199916503436'
    UNION ALL SELECT '0777-46868-0003--066-9400', '199916503450'
    UNION ALL SELECT '0777-46868-0004--066-9400', '199916503467'
    UNION ALL SELECT '0703-48426-0136--010-9500', '199916505843'
    UNION ALL SELECT '0777-46868-0001--010-9300', '199916670312'
    UNION ALL SELECT '0777-46868-0003--066-9500', '199916670367'
    UNION ALL SELECT '0777-46868-0004--066-9500', '199916670374'
    UNION ALL SELECT '0777-48426-0005--045-9500', '199916670503'
    UNION ALL SELECT '0703-48426-0136--001-9200', '199916672903'
    UNION ALL SELECT '0777-46868-0001--010-9500', '199916837036'
    UNION ALL SELECT '0777-46868-0002--010-9500', '199916837050'
    UNION ALL SELECT '0777-46868-0004--066-9100', '199916837074'
    UNION ALL SELECT '0656-61050-0039--075-9900', '199916838521'
    UNION ALL SELECT '0703-48426-0136--001-9500', '199916839603'
    UNION ALL SELECT '0125-61198-0010--004-9100', '460007106738'
    UNION ALL SELECT '0125-61198-0012--103-9100', '460007260751'
    UNION ALL SELECT '0097-60326-1766--010-9600', '460100217522'
),
p AS (
    SELECT sku COLLATE DATABASE_DEFAULT AS sku,
           upc COLLATE DATABASE_DEFAULT AS upc,
           LEFT(sku, CHARINDEX('--', sku) - 1) COLLATE DATABASE_DEFAULT AS itemid,
           LEFT(SUBSTRING(sku, CHARINDEX('--', sku) + 2, 50), CHARINDEX('-', SUBSTRING(sku, CHARINDEX('--', sku) + 2, 50)) - 1) COLLATE DATABASE_DEFAULT AS color,
           SUBSTRING(SUBSTRING(sku, CHARINDEX('--', sku) + 2, 50), CHARINDEX('-', SUBSTRING(sku, CHARINDEX('--', sku) + 2, 50)) + 1, 50) COLLATE DATABASE_DEFAULT AS size
    FROM inp
)
SELECT p.sku, p.upc,
       CASE WHEN LEN(p.upc) = 12 AND p.upc NOT LIKE '%[^0-9]%' THEN
            CASE WHEN (10 - ((CAST(SUBSTRING(p.upc,1,1) AS int) + CAST(SUBSTRING(p.upc,3,1) AS int) + CAST(SUBSTRING(p.upc,5,1) AS int)
                            + CAST(SUBSTRING(p.upc,7,1) AS int) + CAST(SUBSTRING(p.upc,9,1) AS int) + CAST(SUBSTRING(p.upc,11,1) AS int)) * 3
                            + CAST(SUBSTRING(p.upc,2,1) AS int) + CAST(SUBSTRING(p.upc,4,1) AS int) + CAST(SUBSTRING(p.upc,6,1) AS int)
                            + CAST(SUBSTRING(p.upc,8,1) AS int) + CAST(SUBSTRING(p.upc,10,1) AS int)) % 10) % 10
                      = CAST(SUBSTRING(p.upc,12,1) AS int) THEN 'Y' ELSE 'N' END
            ELSE 'n/a' END AS check_digit_ok,
       CASE WHEN u.on_this_sku > 0 THEN 'MATCH'
            WHEN u.n > 0 THEN 'UPC ON DIFFERENT SKU'
            WHEN s.n > 0 THEN 'SKU HAS DIFFERENT UPC'
            ELSE 'NOT FOUND' END AS status,
       u.d365_skus_for_upc, u.setup_primary_synced_blocked,
       s.d365_upcs_for_sku,
       v.retailvariantid,
       (SELECT COUNT(*) FROM pacwmbarcodexrefmessage x WHERE x.xrbrcd = p.upc AND ISNULL(x.IsDelete,0) = 0) AS wm_xref_rows,
       (SELECT COUNT(*) FROM pacsfccproductcatalogvariants c WHERE c.upc = p.upc AND ISNULL(c.IsDelete,0) = 0) AS sfcc_catalog_rows
FROM p
OUTER APPLY (
    SELECT COUNT(*) AS n, SUM(t.hit) AS on_this_sku,
           STRING_AGG(t.owner_sku, '; ') AS d365_skus_for_upc,
           STRING_AGG(t.flags, '; ') AS setup_primary_synced_blocked
    FROM (
        SELECT CASE WHEN b.itemid = p.itemid AND d.inventcolorid = p.color AND d.inventsizeid = p.size THEN 1 ELSE 0 END AS hit,
               b.itemid + '-' + d.inventcolorid + '-' + d.inventsizeid AS owner_sku,
               b.barcodesetupid + '/' + CAST(b.pacprimary AS varchar(1)) + '/' + CAST(b.pacsyncedtowm AS varchar(1)) + '/' + CAST(b.blocked AS varchar(1)) AS flags
        FROM inventitembarcode b
        JOIN inventdim d ON d.inventdimid = b.inventdimid AND d.dataareaid = b.dataareaid
        WHERE b.dataareaid = '1001' AND ISNULL(b.IsDelete,0) = 0 AND b.itembarcode = p.upc
    ) t
) u
OUTER APPLY (
    SELECT COUNT(*) AS n, STRING_AGG(b.itembarcode + ' (' + b.barcodesetupid + ')', '; ') AS d365_upcs_for_sku
    FROM inventitembarcode b
    JOIN inventdim d ON d.inventdimid = b.inventdimid AND d.dataareaid = b.dataareaid
    WHERE b.dataareaid = '1001' AND ISNULL(b.IsDelete,0) = 0
      AND b.itemid = p.itemid AND d.inventcolorid = p.color AND d.inventsizeid = p.size
) s
OUTER APPLY (
    SELECT STRING_AGG(c.retailvariantid, '; ') AS retailvariantid
    FROM inventdimcombination c
    JOIN inventdim d ON d.inventdimid = c.inventdimid AND d.dataareaid = c.dataareaid
    WHERE c.dataareaid = '1001' AND ISNULL(c.IsDelete,0) = 0
      AND c.itemid = p.itemid AND d.inventcolorid = p.color AND d.inventsizeid = p.size
) v
ORDER BY status, p.sku
