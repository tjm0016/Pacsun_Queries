-- Active D365 sales-price trade agreements (pricedisctable relation 4) by price group, as of a date.
-- Price grain is item + color (inventdim carries color only; ~263 rows are size-specific).
-- Take the latest fromdate (then recid) per item/color/size/group. Group names are upper-cased
-- because a few rows carry 'chain' / 'whsl' in lower case.
-- Used 2026-09-30 to find 4905 SKUs Robling values at the stale CHAIN migration price.
DECLARE @asof date = '2026-09-30';
SELECT p.itemrelation AS itemid, d.inventcolorid AS color, d.inventsizeid AS size,
       UPPER(p.accountrelation) AS price_group, p.amount, p.fromdate, p.todate, p.recid, p.createddatetime
FROM pricedisctable p
JOIN inventdim d ON d.inventdimid = p.inventdimid AND d.dataareaid = p.dataareaid
WHERE p.relation = 4 AND p.dataareaid = '1001'
  AND p.fromdate <= @asof
  AND (p.todate = '1900-01-01' OR p.todate >= @asof);

-- Trade agreement journals that created an item's prices
SELECT h.journalnum, h.name, h.posted, t.accountrelation, t.amount, t.fromdate, t.todate, t.createddatetime
FROM pricediscadmtrans t
LEFT JOIN pricediscadmtable h ON h.journalnum = t.journalnum AND h.dataareaid = t.dataareaid
WHERE t.itemrelation = '0860-60218-0166'
ORDER BY t.createddatetime;

-- What 4905 actually sold at (MAO ecom via POS). transdate is 1900-01-01 in Synapse: use createddatetime.
SELECT s.itemid, d.inventcolorid AS color, s.price, COUNT(*) AS lines, SUM(-s.qty) AS units, MAX(s.createddatetime) AS last_sold
FROM retailtransactionsalestrans s
JOIN inventdim d ON d.inventdimid = s.inventdimid AND d.dataareaid = s.dataareaid
WHERE s.store = '4905' AND s.createddatetime >= '2026-08-01' AND s.qty < 0 AND s.price > 0
GROUP BY s.itemid, d.inventcolorid, s.price;
