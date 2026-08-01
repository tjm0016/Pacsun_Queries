-- Chain-wide transit warehouse phantom stock: per-store summary.
-- For every retail transit warehouse (inventlocation type 2, '%-T'), compares inventsum
-- physical on-hand against open cartons (shipped, receiveddatetime = 1900-01-01 sentinel).
-- phantom_net > 0 = units on the books at NNNN-T with no open carton behind them.
-- Synapse serverless, base tables, dataareaid 1001. 2026-07-31.
WITH transit AS (
  SELECT inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
),
onhand AS (
  SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         SUM(s.physicalinvent) AS units
  FROM inventsum s
  JOIN inventdim d ON s.inventdimid=d.inventdimid AND s.dataareaid=d.dataareaid AND s.partition=d.partition
  WHERE s.dataareaid='1001' AND ISNULL(s.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
    AND d.inventlocationid COLLATE DATABASE_DEFAULT IN (SELECT twh FROM transit)
  GROUP BY d.inventlocationid
),
cartons AS (
  SELECT h.towh COLLATE DATABASE_DEFAULT AS storewh,
         SUM(l.cartonquantity) AS units,
         COUNT(DISTINCT h.cartonnumber) AS open_cartons
  FROM paccartontransferheader h
  JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
  WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
    AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
    AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
  GROUP BY h.towh
)
SELECT t.twh, t.storewh,
       ISNULL(o.units, 0)  AS d365_onhand_units,
       ISNULL(c.units, 0)  AS open_carton_units,
       ISNULL(c.open_cartons, 0) AS open_carton_count,
       ISNULL(o.units, 0) - ISNULL(c.units, 0) AS phantom_net
FROM transit t
LEFT JOIN onhand  o ON o.twh = t.twh
LEFT JOIN cartons c ON c.storewh = t.storewh
ORDER BY phantom_net DESC;
