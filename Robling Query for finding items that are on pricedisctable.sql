--Correct Query, original from Robling slightly optimized
    -- Records without size
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM 
    PRICEDISCTABLE p
JOIN 
    INVENTDIM d
        ON p.inventdimid = d.inventdimid
        AND p.dataareaid = d.dataareaid
JOIN 
    INVENTDIM id
        ON d.inventcolorid = id.inventcolorid
        AND d.dataareaid = id.dataareaid
JOIN 
    INVENTDIMCOMBINATION c
        ON id.inventdimid = c.inventdimid
        AND id.dataareaid = c.dataareaid
        AND p.itemrelation = c.itemid
WHERE 
        d.inventsizeid IS NULL
    AND p.accountrelation = 'RETAIL'
    AND p.module = 1
    AND p.relation = 4
    AND p.fromdate >= '2026-06-16' --From date on trade agreement(s)
    AND p.fromdate < '2026-06-17' --From date on trade agreement(s) +1
UNION ALL
    -- Records with size
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM 
    PRICEDISCTABLE p
JOIN 
    INVENTDIM d
        ON p.inventdimid = d.inventdimid
        AND p.dataareaid = d.dataareaid
JOIN 
    INVENTDIM id
        ON d.inventdimid = id.inventdimid
        AND d.dataareaid = id.dataareaid
JOIN 
    INVENTDIMCOMBINATION c
        ON id.inventdimid = c.inventdimid
        AND id.dataareaid = c.dataareaid
        AND p.itemrelation = c.itemid
WHERE 
        d.inventsizeid IS NOT NULL
    AND p.accountrelation = 'RETAIL'
    AND p.module = 1
    AND p.relation = 4
    AND p.fromdate >= '2026-06-16' --From date on trade agreement(s)
    AND p.fromdate < '2026-06-17' --From date on trade agreement(s) +1
ORDER BY 
    p.itemrelation, c.retailvariantid;

--Query that adds in a concatenated column to create LongSKU
SELECT
    p.accountrelation,
    c.retailvariantid,
    p.itemrelation,
    p.amount,
    p.fromdate,
    p.todate,
    id.inventsizeid,
    id.inventcolorid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid,
    CONCAT(p.itemrelation, '-', id.InventColorId, '-', id.InventSizeId) AS LongSKU
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventcolorid = id.inventcolorid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NULL
    AND p.accountrelation = 'RETAIL'
    AND p.module = 1
    AND p.relation = 4
    AND p.fromdate >= '2026-05-12'
    AND p.fromdate < '2026-05-13'
UNION ALL
    -- Records with size
SELECT
    p.accountrelation,
    c.retailvariantid,
    p.itemrelation,
    p.amount,
    p.fromdate,
    p.todate,
    id.inventsizeid,
    id.inventcolorid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid,
    CONCAT(p.itemrelation, '-', id.InventColorId, '-', id.InventSizeId) AS LongSKU
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventdimid = id.inventdimid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NOT NULL
    AND p.accountrelation = 'RETAIL'
    AND p.module = 1
    AND p.relation = 4
    AND p.fromdate >= '2026-05-12'
    AND p.fromdate < '2026-05-13'
ORDER BY c.retailvariantid;

--Query to find MD items with the previous price records for comparison
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventcolorid = id.inventcolorid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NULL
    AND p.fromdate >= '2026-05-19' --From date on the trade agreement
    AND p.fromdate < '2026-05-20' --From date on the trade agreement plus 1
    AND p.accountrelation = 'RETAIL'
    --AND p.accountrelation <> 'WHSL'
    --AND p.accountrelation <> '4110'
    --AND p.accountrelation <> 'ECOM'
    AND p.module = 1
    AND p.relation = 4
UNION ALL
--Pulls the expiring records 
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventcolorid = id.inventcolorid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NULL
    AND p.todate >= '2026-05-18' --From date on the trade agreement minus 1
    AND p.todate < '2026-05-19' --From date on the trade agreement
    --AND p.accountrelation <> 'WHSL'
    --AND p.accountrelation <> '4110'
    --AND p.accountrelation <> 'ECOM'
    AND p.module = 1
    AND p.relation = 4
ORDER BY 
    p.accountrelation, c.retailvariantid, p.fromdate

--Query for MD's ~ fill in the dates on the query
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventcolorid = id.inventcolorid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NULL
    AND p.fromdate >= '2026-06-09' --From date on the trade agreement
    AND p.fromdate < '2026-06-10' --From date on the trade agreement plus 1
    AND p.accountrelation = 'RETAIL'
    --AND p.accountrelation <> 'WHSL'
    --AND p.accountrelation <> '4110'
    --AND p.accountrelation <> 'ECOM'
    AND p.module = 1
    AND p.relation = 4
UNION ALL
--Pulls the expiring records 
SELECT
    c.retailvariantid,
    p.itemrelation,
    id.inventcolorid,
    p.amount,
    p.fromdate,
    p.todate,
    p.accountrelation,
    id.inventsizeid,
    p.pacmarkdowntype,
    c.pacproductmarkdowntypeid as 'Variant MD'
FROM PRICEDISCTABLE p
JOIN INVENTDIM d
    ON p.inventdimid = d.inventdimid
    AND p.dataareaid = d.dataareaid
JOIN INVENTDIM id
    ON d.inventcolorid = id.inventcolorid
    AND d.dataareaid = id.dataareaid
JOIN INVENTDIMCOMBINATION c
    ON id.inventdimid = c.inventdimid
    AND id.dataareaid = c.dataareaid
    AND p.itemrelation = c.itemid
WHERE d.inventsizeid IS NULL
    AND p.todate >= '2026-06-08' --From date on the trade agreement minus 1
    AND p.todate < '2026-06-09' --From date on the trade agreement
    --AND p.accountrelation <> 'WHSL'
    --AND p.accountrelation <> '4110'
    --AND p.accountrelation <> 'ECOM'
    AND p.module = 1
    AND p.relation = 4
ORDER BY 
    p.accountrelation, c.retailvariantid, p.fromdate