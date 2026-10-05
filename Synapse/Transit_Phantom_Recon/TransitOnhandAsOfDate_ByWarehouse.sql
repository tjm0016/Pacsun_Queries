-- -T (in-transit) physical on-hand per transit warehouse AS OF a date, from InventTrans.
-- Reproduces the "D365 OH" by-date export for -T warehouses to the unit (validated 2026-10-05
-- against 'D365 OH 08.15-08.22.xlsx': all 8 days, all 325 -T warehouses, diff = 0).
-- Date basis = inventtrans.datephysical = the POSTING date of the CTN-TRANSFER journal, NOT the
-- carton's ship/scan time. Receive legs post after midnight PT on weekdays -> dated the next day.
-- Synapse serverless prod, base tables. Company 1001.
DECLARE @asof date = '2026-08-22';

SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS warehouse,
       SUM(t.qty) AS onhand_qty
FROM inventtrans t
JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0 AND ISNULL(d.IsDelete,0) = 0
  AND d.inventlocationid LIKE '%-T'
  AND (t.statusreceipt IN (1,2) OR t.statusissue IN (1,2))   -- physically posted (Purchased/Received, Sold/Deducted)
  AND t.datephysical <= @asof
GROUP BY d.inventlocationid
HAVING SUM(t.qty) <> 0
ORDER BY d.inventlocationid;
