--Query to find barcode related information for the Levi item that was called out by business
SELECT
    idc.retailvariantid,
    idc.itemid,
    id.InventColorId,
    id.InventSizeId,
    it.pacvendorstyle,
    iib.itemBarCode,
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
JOIN
    InventItemBarcode iib
        ON iib.retailvariantid = idc.retailvariantid
WHERE
    it.pacvendorstyle = 'A74980027'
ORDER BY
    idc.retailvariantid