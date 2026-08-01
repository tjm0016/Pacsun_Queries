-- Chain-wide transit warehouse phantom stock: SKU-level detail.
-- Same comparison as TransitPhantom_SummaryByStore but at itemid+color+size grain;
-- returns only SKUs where D365 -T on-hand disagrees with open-carton expectation.
-- Carton line color/size match inventdim.inventcolorid/inventsizeid directly.
-- Synapse serverless, base tables, dataareaid 1001. 2026-07-31.
WITH transit AS (
  SELECT inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
),
onhand AS (
  SELECT tr.storewh,
         s.itemid COLLATE DATABASE_DEFAULT AS itemid,
         d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
         d.inventsizeid COLLATE DATABASE_DEFAULT AS size,
         SUM(s.physicalinvent) AS units
  FROM inventsum s
  JOIN inventdim d ON s.inventdimid=d.inventdimid AND s.dataareaid=d.dataareaid AND s.partition=d.partition
  JOIN transit tr ON tr.twh = d.inventlocationid COLLATE DATABASE_DEFAULT
  WHERE s.dataareaid='1001' AND ISNULL(s.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
  GROUP BY tr.storewh, s.itemid, d.inventcolorid, d.inventsizeid
  HAVING SUM(s.physicalinvent) <> 0
),
cartons AS (
  SELECT h.towh COLLATE DATABASE_DEFAULT AS storewh,
         l.itemid COLLATE DATABASE_DEFAULT AS itemid,
         l.color COLLATE DATABASE_DEFAULT AS color,
         l.size COLLATE DATABASE_DEFAULT AS size,
         SUM(l.cartonquantity) AS units
  FROM paccartontransferheader h
  JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
  WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
    AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
    AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
  GROUP BY h.towh, l.itemid, l.color, l.size
)
SELECT COALESCE(o.storewh, c.storewh) AS storewh,
       COALESCE(o.itemid,  c.itemid)  AS itemid,
       COALESCE(o.color,   c.color)   AS color,
       COALESCE(o.size,    c.size)    AS size,
       ISNULL(o.units, 0) AS d365_onhand_units,
       ISNULL(c.units, 0) AS open_carton_units,
       ISNULL(o.units, 0) - ISNULL(c.units, 0) AS diff
FROM onhand o
FULL OUTER JOIN cartons c
  ON  o.storewh = c.storewh AND o.itemid = c.itemid
  AND o.color   = c.color   AND o.size   = c.size
WHERE ISNULL(o.units, 0) <> ISNULL(c.units, 0);
