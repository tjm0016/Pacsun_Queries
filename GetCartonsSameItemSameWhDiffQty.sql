WITH AggregatedCartons AS (
    SELECT 
        h.CartonNumber, h.fromwh, h.ToWh, l.ItemId, l.Size, l.Color, p.RETAILVARIANTID, 
        h.CreatedDateTime, h.receiveddatetime, h.cartonstatus,
        SUM(l.CartonQuantity) AS TotalCartonQty,
        SUM(l.ReceivedQuantity) AS TotalReceivedQty
    FROM PacCartonTransferHeader AS h
    JOIN PacCartonTransferLine AS l ON h.CartonNumber = l.CartonNumber
    JOIN INVENTDIM AS pDim 
      ON pDim.INVENTCOLORID = l.color AND pDim.INVENTSIZEID = l.size AND pDim.DATAAREAID = l.DATAAREAID
    JOIN INVENTDIMCOMBINATION AS p 
      ON p.INVENTDIMID = pDim.INVENTDIMID AND p.ITEMID = l.ITEMID
    WHERE h.CreatedDateTime >= '2026-05-08'
    GROUP BY h.CartonNumber, h.fromwh, h.ToWh, l.ItemId, l.Size, l.Color, p.RETAILVARIANTID,
             h.CreatedDateTime, h.receiveddatetime, h.cartonstatus
),
DuplicateGroups AS (
    SELECT ItemId, Size, Color, RETAILVARIANTID, ToWh
    FROM AggregatedCartons
    GROUP BY ItemId, Size, Color, RETAILVARIANTID, ToWh 
    HAVING COUNT(CartonNumber) > 1
)
SELECT 
    ac.CartonNumber,ac.fromwh, ac.ToWh, ac.ItemId, ac.Size, ac.Color, ac.RETAILVARIANTID,
    ac.CreatedDateTime, ac.receiveddatetime,
    CASE
        WHEN ac.cartonstatus = 4 THEN 'Complete'
        WHEN ac.cartonstatus = 3 THEN 'Acknowledged'
        WHEN ac.cartonstatus = 2 THEN 'POD, not acknowledged'
        WHEN ac.cartonstatus = 1 THEN 'In-transit'
        WHEN ac.cartonstatus = 0 THEN 'Created'
    END AS CartonStatusLabel,
    ac.TotalCartonQty,
    ac.TotalReceivedQty
FROM AggregatedCartons ac
JOIN DuplicateGroups dg 
  ON ac.ItemId = dg.ItemId 
  AND ac.Size = dg.Size 
  AND ac.Color = dg.Color 
  AND ac.RETAILVARIANTID = dg.RETAILVARIANTID 
  AND ac.ToWh = dg.ToWh
WHERE EXISTS (
    SELECT 1 
    FROM AggregatedCartons ac2 
    WHERE ac2.CartonNumber = ac.CartonNumber 
      AND (ac2.TotalReceivedQty > ac2.TotalCartonQty OR ac2.TotalReceivedQty = 0)
)
ORDER BY ac.CartonNumber ASC, ac.ItemId, ac.Size, ac.Color, ac.ToWh;
