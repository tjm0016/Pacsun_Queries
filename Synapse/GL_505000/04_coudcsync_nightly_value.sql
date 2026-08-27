SELECT CAST(t.transdate AS date)       AS transdate,
       jt.posted,
       dim.inventlocationid            AS warehouse,
       COUNT(DISTINCT jt.journalid)    AS journals,
       COUNT(*)                        AS lines,
       SUM(t.qty)                      AS net_qty,
       SUM(t.costamount)               AS net_costamount,
       MIN(jt.createddatetime)         AS first_created_utc
FROM dbo.inventjournaltable jt
JOIN dbo.inventjournaltrans t ON t.journalid COLLATE DATABASE_DEFAULT = jt.journalid COLLATE DATABASE_DEFAULT
LEFT JOIN dbo.inventdim dim   ON dim.inventdimid COLLATE DATABASE_DEFAULT = t.inventdimid COLLATE DATABASE_DEFAULT
WHERE jt.journalnameid = 'COU-DCSYNC'
  AND t.transdate >= '2026-08-10'
GROUP BY CAST(t.transdate AS date), jt.posted, dim.inventlocationid
ORDER BY 1, 3;
