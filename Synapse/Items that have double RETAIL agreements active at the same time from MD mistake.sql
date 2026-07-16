--Items that have double RETAIL agreements active at the same time

--CHAIN
WITH CTE AS (
            SELECT
                pdt.itemrelation,
                id.inventcolorid,
                pdt.accountrelation,
                pdt.amount,
                pdt.fromdate,
                pdt.todate,
                pdt.pacmarkdowntype,
                COUNT(*) OVER (PARTITION BY pdt.itemrelation, id.inventcolorid, pdt.accountrelation) AS duplicate_count,
                ROW_NUMBER() OVER (PARTITION BY pdt.itemrelation,id.inventcolorid,pdt.accountrelation ORDER BY pdt.fromdate) AS rn
            FROM 
	            pricedisctable pdt
            JOIN
	            inventdim id
		            ON pdt.inventdimid = id.inventdimid
                        AND pdt.dataareaid = id.dataareaid
            WHERE 
	            pdt.accountrelation = 'CHAIN'
                AND id.inventsizeid IS NULL
                AND pdt.todate = '1900-01-01 00:00:00.0000000'
                )
SELECT
    itemrelation,
    inventcolorid,
    accountrelation,
    amount,
    fromdate,
    todate,
    pacmarkdowntype
FROM 
    CTE
WHERE 
    duplicate_count > 1
    AND rn = 1
ORDER BY 
    itemrelation,
    inventcolorid,
    fromdate
;

--RETAIL
WITH CTE AS (
            SELECT
                pdt.itemrelation,
                id.inventcolorid,
                pdt.accountrelation,
                pdt.amount,
                pdt.fromdate,
                pdt.todate,
                pdt.pacmarkdowntype,
                COUNT(*) OVER (PARTITION BY pdt.itemrelation, id.inventcolorid, pdt.accountrelation) AS duplicate_count,
                ROW_NUMBER() OVER (PARTITION BY pdt.itemrelation,id.inventcolorid,pdt.accountrelation ORDER BY pdt.fromdate) AS rn
            FROM 
	            pricedisctable pdt
            JOIN
	            inventdim id
		            ON pdt.inventdimid = id.inventdimid
                        AND pdt.dataareaid = id.dataareaid
            WHERE 
	            pdt.accountrelation = 'RETAIL'
                AND id.inventsizeid IS NULL
                AND pdt.todate = '1900-01-01 00:00:00.0000000'
                )
SELECT
    itemrelation,
    inventcolorid,
    accountrelation,
    amount,
    fromdate,
    todate,
    pacmarkdowntype
FROM 
    CTE
WHERE 
    duplicate_count > 1
    AND rn = 1
ORDER BY 
    itemrelation,
    inventcolorid,
    fromdate
;

--ECOM
WITH CTE AS (
            SELECT
                pdt.itemrelation,
                id.inventcolorid,
                pdt.accountrelation,
                pdt.amount,
                pdt.fromdate,
                pdt.todate,
                pdt.pacmarkdowntype,
                COUNT(*) OVER (PARTITION BY pdt.itemrelation, id.inventcolorid, pdt.accountrelation) AS duplicate_count,
                ROW_NUMBER() OVER (PARTITION BY pdt.itemrelation,id.inventcolorid,pdt.accountrelation ORDER BY pdt.fromdate) AS rn
            FROM 
	            pricedisctable pdt
            JOIN
	            inventdim id
		            ON pdt.inventdimid = id.inventdimid
                        AND pdt.dataareaid = id.dataareaid
            WHERE 
	            pdt.accountrelation = 'ECOM'
                AND id.inventsizeid IS NULL
                AND pdt.todate = '1900-01-01 00:00:00.0000000'
                )
SELECT
    itemrelation,
    inventcolorid,
    accountrelation,
    amount,
    fromdate,
    todate,
    pacmarkdowntype
FROM 
    CTE
WHERE 
    duplicate_count > 1
    AND rn = 1
ORDER BY 
    itemrelation,
    inventcolorid,
    fromdate
;