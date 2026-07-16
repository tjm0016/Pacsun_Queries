--Query that uses '%[^a-zA-Z0-9 ]%'
SELECT
	idc.retailvariantid,
    it.itemid,
    ept.description,
    id.inventcolorid,
    id.inventsizeid
FROM 
    inventtable it
JOIN
    inventdimcombination idc
        ON idc.ItemId = it.ItemId
            AND idc.dataareaid = it.dataareaid
JOIN
    InventDim id
        ON id.InventDimId = idc.InventDimId
            AND id.DataAreaId = idc.DataAreaId
JOIN 
    EcoResProductTranslation ept
        ON ept.product = it.product
WHERE
    ept.description IS NOT NULL
    --AND ept.description LIKE '%[^ -~]%'
    AND PATINDEX('%[^a-zA-Z0-9 ]%', ept.description) > 0
ORDER BY 
    it.itemid, idc.retailvariantid;

--Query that uses '%[^ -~]%'
SELECT
	idc.retailvariantid,
    it.itemid,
    ept.description,
    id.inventcolorid,
    id.inventsizeid
FROM 
    inventtable it
JOIN
    inventdimcombination idc
        ON idc.ItemId = it.ItemId
            AND idc.dataareaid = it.dataareaid
JOIN
    InventDim id
        ON id.InventDimId = idc.InventDimId
            AND id.DataAreaId = idc.DataAreaId
JOIN 
    EcoResProductTranslation ept
        ON ept.product = it.product
WHERE
    ept.description IS NOT NULL
    AND ept.description LIKE '%[^ -~]%'
    OR (
           ept.description LIKE '%Â%'
        OR ept.description LIKE '%Ã‰%'
        OR ept.description LIKE '%"%'
        OR ept.description LIKE '%"%'
        OR ept.description LIKE '%Ãˆ%'
        OR ept.description LIKE '%Ã%'
        OR ept.description LIKE '%À%'
        OR ept.description LIKE '%Ã%'
        OR ept.description LIKE '%ÃŒ%'
        OR ept.description LIKE '%Ã"%'
        OR ept.description LIKE '%Ã’%'
        OR ept.description LIKE '%Ãš%'
        OR ept.description LIKE '%Ã™%'
        OR ept.description LIKE '%Ã’%'
        OR ept.description LIKE '%Ã%'
        OR ept.description LIKE '%Ã›%'
        OR ept.description LIKE '%Â¼%'
        OR ept.description LIKE '%Ã‚%'
        OR ept.description LIKE '%Â®%'
        OR ept.description LIKE '%:%'
        OR ept.description LIKE '%`%'
        OR ept.description LIKE '%"%'
        OR ept.description LIKE '%/%'
        OR ept.description LIKE '%\%'
        OR ept.description LIKE '%’%'  -- escaped single quote
        OR ept.description LIKE '%*%'
        OR ept.description LIKE '%?%'
    )
ORDER BY 
    it.itemid, idc.retailvariantid;




--Query to see columns in EcoResProductTranslation 
SELECT TOP 5 
    *
FROM
    EcoResProductTranslation 

--Query to see columns in inventtable
SELECT TOP 5 
    *
FROM
    inventtable