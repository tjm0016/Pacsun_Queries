-- RECEIVE-JOURNAL LAG: units still in NNNN-T books as of @asof that BI already counts received.
-- The daily D365-vs-BI transit variance driver (proven store 1234, 8/1: 34 cartons / 1,681 units;
-- chain: receive batch runs ~00:00 Pacific, median lag 14.7h, 88% next-day transdates).
-- Run summary or swap in the carton-level SELECT at the bottom for drill.
-- Synapse serverless prod, base tables, dataareaid 1001. 2026-08-02.
DECLARE @asof  date        = '2026-08-01';
DECLARE @store varchar(10) = NULL;          -- e.g. '1234'; NULL = all stores

SELECT h.towh                                   AS store,
       COUNT(DISTINCT h.cartonnumber)           AS lag_cartons,
       SUM(l.cartonquantity)                    AS lag_units
FROM paccartontransferheader h
JOIN paccartontransferline l
  ON l.cartonnumber = h.cartonnumber AND l.dataareaid = h.dataareaid AND l.partition = h.partition
OUTER APPLY (
    SELECT MAX(j.transdate) AS recv_transdate
    FROM inventjournaltable j
    WHERE j.dataareaid = '1001' AND ISNULL(j.IsDelete,0) = 0
      AND j.journalnameid COLLATE DATABASE_DEFAULT = 'CTN-TRANSFER'
      AND j.paccartontransfernumber COLLATE DATABASE_DEFAULT = h.cartonnumber COLLATE DATABASE_DEFAULT
      AND j.createddatetime >= h.receiveddatetime
) rj
WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0 AND ISNULL(l.IsDelete,0) = 0
  AND h.receiveddatetime > '1900-01-02'                                -- really received (skips sentinel + corrupted-1900 rows)
  AND CAST(DATEADD(hour, -7, h.receiveddatetime) AS date) <= @asof     -- Pacific EOP day (-7 PDT / -8 PST)
  AND h.receiveddatetime >= DATEADD(day, -14, CAST(@asof AS datetime)) -- perf bound; drop to sweep stuck cartons
  AND (rj.recv_transdate IS NULL OR rj.recv_transdate > @asof)
  AND (@store IS NULL OR h.towh = @store)
GROUP BY h.towh
ORDER BY lag_units DESC;

/* Carton-level drill: replace the SELECT/GROUP BY above with:
SELECT h.towh AS store, h.cartonnumber, h.fromwh, h.receiveddatetime,
       rj.recv_transdate AS receive_journal_transdate, SUM(l.cartonquantity) AS units
...
GROUP BY h.towh, h.cartonnumber, h.fromwh, h.receiveddatetime, rj.recv_transdate
ORDER BY h.towh, h.receiveddatetime;  */
