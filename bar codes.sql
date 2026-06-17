--Query to find items that do not have barcodes in prod
SELECT
    idc.retailvariantid,
    idc.itemid,
    id.InventColorId,
    id.InventSizeId,
    it.pacvendorstyle,
    idc.pacproductdropshipid,
    idc.createddatetime
FROM 
    inventdimcombination idc
JOIN 
    InventDim id
        ON idc.InventDimId = id.InventDimId
JOIN 
    inventtable it
        ON idc.itemid = it.itemid
WHERE 
    it.pacvendorstyle NOT LIKE 'DNU%'
    AND NOT EXISTS (
                    SELECT 
                        1
                    FROM 
                        InventItemBarcode iib
                    WHERE 
                        iib.retailvariantid = idc.retailvariantid
                    )
ORDER BY
    idc.createddatetime,
    idc.itemid,
    idc.retailvariantid
    ;

--Query to find the count of all primary barcodes in prod
select 
    count(*) AS 'Item barcodes'
FROM 
    InventItemBarcode
WHERE 
    pacPrimary = '1'

--Query to find the count of ALL Short skus in prod
SELECT 
    count(RetailVariantId) AS 'Short skus'
FROM 
    InventDimCombination 