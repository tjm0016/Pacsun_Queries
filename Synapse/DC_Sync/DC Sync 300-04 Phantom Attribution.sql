/* DC Sync - PIX 300/04 phantom-relief attribution (Synapse, D365 prod)
   How much of a 4905 COU-DCSYNC journal is the sync adding back phantom Active relief from
   PIX 300/04 (blank action) lines whose pxtran also carries a 300/01/01 'A' leg (that leg has no
   row in pacwmpixtransactionmappingtable, so only the subtract posts).
   Window = MOV-DCADJ journals created between the previous 4905 sync journal and this one.
   Set the two journal ids in phantom_lines (prior / current) and in journal_lines / journal_totals.
   Per-key attribution (done in Python): attributed = MIN(MAX(journal qty,0), -phantom qty) per itemid+inventdimid.
   First used 2026-10-20 for the 10/19 sync (INV-02358744): 1,968 u / $70,522 of +2,196 u / +$79,334. */
-- ## phantom_lines
WITH w AS (SELECT (SELECT createddatetime FROM dbo.inventjournaltable WHERE journalid='INV-02337326') t0,
                  (SELECT createddatetime FROM dbo.inventjournaltable WHERE journalid='INV-02358744') t1),
a AS (SELECT pxtran, MAX(pxcasn) casn FROM dbo.pacwmpixmessage WHERE createddatetime >= '2026-10-17' AND pxtxtp='300' AND pxtxcd='01' AND pxaccd='01' AND pxinat='A' GROUP BY pxtran),
x AS (SELECT DISTINCT pxcasn FROM dbo.pacwmpixmessage WHERE createddatetime >= '2026-10-17' AND pxtxtp='300' AND pxtxcd='01' AND pxaccd='22')
SELECT t.journalid mov_journal, CONVERT(varchar(19), j.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time',120) created_pt,
  j.posted, t.pacwmpxtran pxtran, a.casn case_no, CASE WHEN x.pxcasn IS NULL THEN 'N' ELSE 'Y' END codiv_transfer_same_case,
  t.pacwmmessageid message_id, t.itemid, it.namealias item_name, d.inventcolorid color, d.inventsizeid size, d.wmslocationid bucket, t.inventdimid,
  t.qty, CAST(t.costamount AS decimal(14,2)) cost
FROM dbo.inventjournaltrans t JOIN dbo.inventjournaltable j ON j.journalid=t.journalid
JOIN dbo.inventdim d ON d.inventdimid=t.inventdimid CROSS JOIN w
JOIN a ON a.pxtran=t.pacwmpxtran
LEFT JOIN x ON x.pxcasn=a.casn
LEFT JOIN dbo.inventtable it ON it.itemid=t.itemid
WHERE j.journalnameid='MOV-DCADJ' AND j.createddatetime > w.t0 AND j.createddatetime < w.t1 AND d.inventlocationid='4905'
  AND t.pacwmpxtxtp='300' AND t.pacwmpxtxcd='04' AND ISNULL(t.pacwmpxaccd,'')=''
-- ## journal_lines_4905
SELECT t.journalid, t.itemid, it.namealias item_name, d.inventcolorid color, d.inventsizeid size, d.wmslocationid bucket, t.inventdimid,
  t.counted wm_counted, t.counted-t.qty d365_onhand, t.qty journal_qty, CAST(t.costamount AS decimal(14,2)) journal_cost
FROM dbo.inventjournaltrans t JOIN dbo.inventdim d ON d.inventdimid=t.inventdimid LEFT JOIN dbo.inventtable it ON it.itemid=t.itemid
WHERE t.journalid='INV-02358744'
-- ## journal_totals
SELECT t.journalid, d.inventlocationid loc, j.posted, COUNT(*) lines, SUM(t.qty) qty, CAST(SUM(t.costamount) AS decimal(14,2)) cost,
  SUM(CASE WHEN t.qty>0 THEN t.qty ELSE 0 END) pos_qty, CAST(SUM(CASE WHEN t.qty>0 THEN t.costamount ELSE 0 END) AS decimal(14,2)) pos_cost,
  SUM(CASE WHEN t.qty<0 THEN t.qty ELSE 0 END) neg_qty, CAST(SUM(CASE WHEN t.qty<0 THEN t.costamount ELSE 0 END) AS decimal(14,2)) neg_cost
FROM dbo.inventjournaltrans t JOIN dbo.inventjournaltable j ON j.journalid=t.journalid JOIN dbo.inventdim d ON d.inventdimid=t.inventdimid
WHERE t.journalid IN ('INV-02354158','INV-02358744') GROUP BY t.journalid, d.inventlocationid, j.posted
-- ## prior_nights
WITH a AS (SELECT DISTINCT pxtran FROM dbo.pacwmpixmessage WHERE createddatetime >= '2026-09-28' AND pxtxtp='300' AND pxtxcd='01' AND pxaccd='01' AND pxinat='A'),
jw AS (SELECT j.journalid, j.createddatetime t1, LAG(j.createddatetime) OVER (ORDER BY j.createddatetime) t0
       FROM dbo.inventjournaltable j WHERE j.journalnameid='COU-DCSYNC' AND j.createddatetime >= '2026-09-30'
         AND EXISTS (SELECT 1 FROM dbo.inventjournaltrans t JOIN dbo.inventdim d ON d.inventdimid=t.inventdimid WHERE t.journalid=j.journalid AND d.inventlocationid='4905')),
jt AS (SELECT t.journalid, SUM(t.qty) jqty, SUM(t.costamount) jcost FROM dbo.inventjournaltrans t WHERE t.journalid IN (SELECT journalid FROM jw) GROUP BY t.journalid),
ph AS (SELECT jw.journalid, COUNT(*) lines, SUM(t.qty) pqty, SUM(t.costamount) pcost
       FROM jw JOIN dbo.inventjournaltable j ON j.journalnameid='MOV-DCADJ' AND j.createddatetime > jw.t0 AND j.createddatetime < jw.t1
       JOIN dbo.inventjournaltrans t ON t.journalid=j.journalid JOIN dbo.inventdim d ON d.inventdimid=t.inventdimid
       JOIN a ON a.pxtran=t.pacwmpxtran
       WHERE d.inventlocationid='4905' AND t.pacwmpxtxtp='300' AND t.pacwmpxtxcd='04' AND ISNULL(t.pacwmpxaccd,'')=''
       GROUP BY jw.journalid)
SELECT CONVERT(varchar(16), jw.t1 AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time',120) sync_created_pt, jw.journalid,
  jt.jqty journal_qty, CAST(jt.jcost AS decimal(14,2)) journal_cost, ISNULL(ph.lines,0) phantom_lines, ISNULL(ph.pqty,0) phantom_qty, CAST(ISNULL(ph.pcost,0) AS decimal(14,2)) phantom_cost
FROM jw JOIN jt ON jt.journalid=jw.journalid LEFT JOIN ph ON ph.journalid=jw.journalid WHERE jw.t0 IS NOT NULL ORDER BY jw.t1
