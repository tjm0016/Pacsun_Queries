-- RECEIVE-JOURNAL LAG: units still in NNNN-T books as of @asof that BI already counts received.
-- The daily D365-vs-BI transit variance driver. Validated: store 1234 @ 2026-08-01 = 34 cartons /
-- 1,681 units (matches ledger line-for-line); chain @ 8/1 = 44 stores / 9,265 units; runs ~90s.
-- NOTE: transdate lives on inventjournaltrans (lines), NOT inventjournaltable - hence the jl join.
-- Synapse serverless prod, base tables. 2026-08-02.
DECLARE @asof  date        = '2026-08-01';
DECLARE @store varchar(10) = NULL;   -- e.g. '1234'; NULL = all stores

WITH recv AS (          -- cartons physically received by @asof (Pacific EOP day; -7 PDT / -8 PST)
  SELECT h.cartonnumber COLLATE DATABASE_DEFAULT AS carton, h.towh, h.receiveddatetime
  FROM paccartontransferheader h
  WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0
    AND h.receiveddatetime > '1900-01-02'                                -- really received (skips sentinel + corrupted-1900 rows)
    AND CAST(DATEADD(hour,-7,h.receiveddatetime) AS date) <= @asof
    AND h.receiveddatetime >= DATEADD(day,-14, CAST(@asof AS datetime))  -- perf bound; drop to sweep stuck cartons
    AND (@store IS NULL OR h.towh = @store)
),
jr AS (                 -- each carton's receive journal (created at/after physical receipt; earlier stamped journal = ship leg)
  SELECT r.carton, MAX(jl.transdate) AS recv_transdate
  FROM recv r
  JOIN inventjournaltable j
    ON j.paccartontransfernumber COLLATE DATABASE_DEFAULT = r.carton
   AND j.dataareaid='1001' AND ISNULL(j.IsDelete,0)=0
   AND j.journalnameid COLLATE DATABASE_DEFAULT = 'CTN-TRANSFER'
   AND j.createddatetime >= r.receiveddatetime
  JOIN inventjournaltrans jl
    ON jl.journalid COLLATE DATABASE_DEFAULT = j.journalid COLLATE DATABASE_DEFAULT
   AND jl.dataareaid = j.dataareaid AND ISNULL(jl.IsDelete,0)=0
  GROUP BY r.carton
)
SELECT r.towh AS store, COUNT(DISTINCT r.carton) AS lag_cartons, SUM(l.cartonquantity) AS lag_units
FROM recv r
JOIN paccartontransferline l
  ON l.cartonnumber COLLATE DATABASE_DEFAULT = r.carton AND l.dataareaid='1001' AND ISNULL(l.IsDelete,0)=0
LEFT JOIN jr ON jr.carton = r.carton
WHERE jr.recv_transdate IS NULL          -- receive journal not posted yet
   OR jr.recv_transdate > @asof          -- or posted with a transdate after the cutoff
GROUP BY r.towh
ORDER BY lag_units DESC;

/* Carton-level drill: swap the final SELECT for
SELECT r.towh AS store, r.carton, r.receiveddatetime, jr.recv_transdate, SUM(l.cartonquantity) AS units
...same joins/WHERE...
GROUP BY r.towh, r.carton, r.receiveddatetime, jr.recv_transdate ORDER BY r.towh, r.receiveddatetime;  */
