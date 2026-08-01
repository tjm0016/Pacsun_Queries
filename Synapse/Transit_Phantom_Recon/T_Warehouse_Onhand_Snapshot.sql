-- Current on-hand snapshot for ALL retail transit (-T) warehouses, by SKU.
-- One row per warehouse + item + color + size with net physical on-hand <> 0.
-- Source: D365 Synapse serverless (dataverse_psprod). Company 1001.
-- Qty = SUM(inventsum.physicalinvent) — posted physical on-hand, same measure
-- used by the 2026-07-31 chain transit phantom recon (TransitPhantom_SummaryByStore.sql).

WITH transit AS (
  SELECT inventlocationid COLLATE DATABASE_DEFAULT AS twh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS warehouse,
       s.itemid COLLATE DATABASE_DEFAULT AS itemid,
       d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
       d.inventsizeid COLLATE DATABASE_DEFAULT AS size,
       SUM(s.physicalinvent) AS qty
FROM inventsum s
JOIN inventdim d ON s.inventdimid=d.inventdimid AND s.dataareaid=d.dataareaid AND s.partition=d.partition
JOIN transit tr ON tr.twh = d.inventlocationid COLLATE DATABASE_DEFAULT
WHERE s.dataareaid='1001' AND ISNULL(s.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
GROUP BY d.inventlocationid, s.itemid, d.inventcolorid, d.inventsizeid
HAVING SUM(s.physicalinvent) <> 0
ORDER BY d.inventlocationid, s.itemid, d.inventcolorid, d.inventsizeid;
