--Query to find items that were created with no trade agreements since go-live
    --Distinct on only it.ItemID and d.inventcolorid
WITH CTE AS (
            SELECT
                it.ItemId,
                d.inventcolorid,
                it.createdDateTime,
                idc.pacProductDropShipId,
                ROW_NUMBER() OVER (PARTITION BY it.ItemId, d.inventcolorid ORDER BY idc.createdDateTime) AS rn
            FROM 
                inventtable it
            JOIN
                inventdimcombination idc
                    ON idc.ItemId = it.ItemId
                        AND idc.dataareaid = it.dataareaid
            JOIN
                InventDim d
                    ON d.InventDimId = idc.InventDimId
                        AND d.DataAreaId = idc.DataAreaId
            WHERE 
                NOT EXISTS (
                    SELECT 1
                    FROM PriceDiscTable p
                    JOIN INVENTDIM d2
                        ON p.inventdimid = d2.inventdimid
                            AND p.dataareaid = d2.dataareaid
                    WHERE
                            d2.inventsizeid IS NULL
                        AND p.accountrelation = 'CHAIN'
                        AND p.ItemRelation = it.ItemId
                        AND d2.inventcolorid = d.inventcolorid
                        AND p.module = 1
                        AND p.relation = 4
                )
                AND idc.createdDateTime >= '2026-04-06'
                )
SELECT
    ItemId,
    inventcolorid,
    createdDateTime,
    pacProductDropShipId
FROM 
    CTE
WHERE 
    rn = 1
ORDER BY 
    createdDateTime, ItemId, pacProductDropShipId