/*
PIX Lock Code Mapping Fix Check  (Synapse, D365 prod)

Context: on 2026-10-22 WM (SLG3G7RP/SLG3G8RP) began sending lock refs 49 + 50 on BOTH legs of an
active-location lock add (300/04/05 S + 606/06/05 A) and lock removal (300/04/06 A + 606/06/06 S).
D365 books a 49+50 message as a full from/to move, so each move posted twice. Fix: delete the
300/04/05 and 606/06/06 rows from PIX adjustment mapping.

Set ChangeUtc (all three statements) to the UTC time the rows were deleted.
Checks only PIX files processed after that time. Run 1-2 hours after the change (Synapse lag).

Statement 1  mapping rows       -> every column PASS
Statement 2  summary by flow    -> verdict OK for every flow; zero DOUBLED / LOCK NOT RELIEVED
Statement 3  detail             -> the pxtrans that are not OK (empty = good)
*/

-- 1. Mapping rows: 300/04/05 and 606/06/06 gone, the rows we keep still there
SELECT
    CASE WHEN SUM(CASE WHEN pxtxtp='300' AND pxtxcd='04' AND pxaccd='05' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL - still mapped' END AS [300/04/05 deleted],
    CASE WHEN SUM(CASE WHEN pxtxtp='606' AND pxtxcd='06' AND pxaccd='06' THEN 1 ELSE 0 END) = 0 THEN 'PASS' ELSE 'FAIL - still mapped' END AS [606/06/06 deleted],
    CASE WHEN SUM(CASE WHEN pxtxtp='300' AND pxtxcd='04' AND pxaccd='06' THEN 1 ELSE 0 END) = 1 THEN 'PASS' ELSE 'FAIL - missing' END AS [300/04/06 kept],
    CASE WHEN SUM(CASE WHEN pxtxtp='606' AND pxtxcd='06' AND pxaccd='05' THEN 1 ELSE 0 END) = 1 THEN 'PASS' ELSE 'FAIL - missing' END AS [606/06/05 kept],
    CASE WHEN SUM(CASE WHEN pxtxtp='606' AND pxtxcd='02' AND pxaccd='06' THEN 1 ELSE 0 END) = 1 THEN 'PASS' ELSE 'FAIL - missing' END AS [606/02/06 kept]
FROM pacwmpixtransactionmappingtable;

-- 2. Summary: WM truth vs D365 pending adjustments, per lock/unlock transaction
WITH prm AS (SELECT CAST('2026-10-22 21:00' AS datetime2) AS ChangeUtc),
files AS (
    SELECT s.recid, s.messageid
    FROM sunintmessage s CROSS JOIN prm
    WHERE LEFT(s.messageid, 2) = 'PX' AND s.statusdatetime >= prm.ChangeUtc
),
legs AS (
    SELECT m.recid, m.pxtran, f.messageid,
           CASE WHEN m.pxtxtp='300' AND m.pxaccd='05' THEN '300/04/05' WHEN m.pxtxtp='300' THEN '300/04/06'
                WHEN m.pxtxcd='02' AND m.pxaccd='05' THEN '606/02/05' WHEN m.pxtxcd='02' THEN '606/02/06'
                WHEN m.pxaccd='05' THEN '606/06/05' ELSE '606/06/06' END AS code,
           CASE WHEN m.pxinat = 'A' THEN 1 ELSE -1 END * CAST(m.pxinva AS bigint) / 10000 AS sqty,
           CASE WHEN '50' IN (m.pxrcd1,m.pxrcd2,m.pxrcd3,m.pxrcd4,m.pxrcd5,m.pxrcd6,m.pxrcd7,m.pxrcd8) THEN 1 ELSE 0 END AS has50
    FROM pacwmpixmessage m
    JOIN files f ON f.recid = m.message
    CROSS JOIN prm
    WHERE m.SinkModifiedOn >= DATEADD(day, -2, prm.ChangeUtc)
      AND ((m.pxtxtp='300' AND m.pxtxcd='04' AND m.pxaccd IN ('05','06'))
        OR (m.pxtxtp='606' AND m.pxtxcd IN ('02','06') AND m.pxaccd IN ('05','06')))
),
tx AS (   -- WM transactions that contain an active-location lock add or removal leg
    SELECT pxtran, messageid FROM legs
    WHERE code IN ('300/04/05','300/04/06','606/06/05','606/06/06')
    GROUP BY pxtran, messageid
),
wm AS (
    SELECT l.pxtran, l.messageid,
           SUM(CASE WHEN LEFT(l.code,3)='300' THEN l.sqty ELSE 0 END) AS wm_active,
           SUM(CASE WHEN LEFT(l.code,3)='606' THEN l.sqty ELSE 0 END) AS wm_lock,
           MAX(CASE WHEN LEFT(l.code,3)='606' THEN ABS(l.sqty) ELSE 0 END) AS units,
           MAX(l.has50) AS has50,
           MAX(CASE WHEN l.code='606/06/06' THEN 1 ELSE 0 END) AS f_unlock,
           MAX(CASE WHEN l.code IN ('300/04/05','606/06/05') THEN 1 ELSE 0 END) AS f_add,
           MAX(CASE WHEN l.code='606/02/06' THEN 1 ELSE 0 END) AS f_case
    FROM legs l JOIN tx ON tx.pxtran = l.pxtran AND tx.messageid = l.messageid
    GROUP BY l.pxtran, l.messageid
),
d365 AS (
    SELECT l.pxtran, l.messageid,
           SUM(CASE WHEN ISNULL(d.wmslocationid,'') IN ('','Active') THEN CAST(p.qty AS int) ELSE 0 END) AS d_active,
           SUM(CASE WHEN ISNULL(d.wmslocationid,'') NOT IN ('','Active') THEN CAST(p.qty AS int) ELSE 0 END) AS d_lock,
           COUNT(*) AS d_lines
    FROM legs l
    JOIN pacwmpendingadjustment p ON p.integrationlinerecid = l.recid
    JOIN inventdim d ON d.inventdimid = p.inventdimid
    GROUP BY l.pxtran, l.messageid
),
v AS (
    SELECT w.pxtran, w.messageid, w.units, w.wm_active, w.wm_lock,
           ISNULL(x.d_active,0) AS d_active, ISNULL(x.d_lock,0) AS d_lock, ISNULL(x.d_lines,0) AS d_lines,
           CASE WHEN w.f_unlock = 1 THEN 'Active unlock (300/04/06 + 606/06/06)'
                WHEN w.f_add = 1 AND w.f_case = 0 THEN 'Lock add (606/06/05, +300/04/05 if active)'
                WHEN w.f_case = 1 AND w.f_add = 1 THEN 'Case unlock + relock (606/02/06 + 606/06/05)'
                WHEN w.f_case = 1 THEN 'Case unlock (300/04/06 + 606/02/06)'
                ELSE 'Other' END AS flow,
           CASE WHEN w.has50 = 1 THEN 'new (49+50)' ELSE 'old' END AS layout,
           CASE WHEN ISNULL(x.d_active,0) = w.wm_active AND ISNULL(x.d_lock,0) = w.wm_lock THEN 'OK'
                WHEN w.wm_lock <> 0 AND ISNULL(x.d_active,0) = 2*w.wm_active AND ISNULL(x.d_lock,0) = 2*w.wm_lock THEN 'DOUBLED'
                WHEN w.wm_lock <> 0 AND ISNULL(x.d_lock,0) = 0 THEN 'LOCK NOT RELIEVED'
                ELSE 'MISMATCH' END AS verdict
    FROM wm w LEFT JOIN d365 x ON x.pxtran = w.pxtran AND x.messageid = w.messageid
)
SELECT flow, layout, verdict, COUNT(*) AS pxtrans, SUM(units) AS units,
       MIN(pxtran) AS first_pxtran, MAX(pxtran) AS last_pxtran
FROM v
GROUP BY flow, layout, verdict
ORDER BY flow, layout, verdict;

-- 3. Detail: every transaction that is not OK
WITH prm AS (SELECT CAST('2026-10-22 21:00' AS datetime2) AS ChangeUtc),
files AS (
    SELECT s.recid, s.messageid
    FROM sunintmessage s CROSS JOIN prm
    WHERE LEFT(s.messageid, 2) = 'PX' AND s.statusdatetime >= prm.ChangeUtc
),
legs AS (
    SELECT m.recid, m.pxtran, f.messageid,
           CASE WHEN m.pxtxtp='300' AND m.pxaccd='05' THEN '300/04/05' WHEN m.pxtxtp='300' THEN '300/04/06'
                WHEN m.pxtxcd='02' AND m.pxaccd='05' THEN '606/02/05' WHEN m.pxtxcd='02' THEN '606/02/06'
                WHEN m.pxaccd='05' THEN '606/06/05' ELSE '606/06/06' END AS code,
           CONCAT(m.pxstyl,'-',m.pxssfx,'-',m.pxcolr,'/',m.pxsdim,'/',m.pxszcd) AS sku,
           CASE WHEN m.pxinat = 'A' THEN 1 ELSE -1 END * CAST(m.pxinva AS bigint) / 10000 AS sqty,
           CASE WHEN '50' IN (m.pxrcd1,m.pxrcd2,m.pxrcd3,m.pxrcd4,m.pxrcd5,m.pxrcd6,m.pxrcd7,m.pxrcd8) THEN 1 ELSE 0 END AS has50
    FROM pacwmpixmessage m
    JOIN files f ON f.recid = m.message
    CROSS JOIN prm
    WHERE m.SinkModifiedOn >= DATEADD(day, -2, prm.ChangeUtc)
      AND ((m.pxtxtp='300' AND m.pxtxcd='04' AND m.pxaccd IN ('05','06'))
        OR (m.pxtxtp='606' AND m.pxtxcd IN ('02','06') AND m.pxaccd IN ('05','06')))
),
tx AS (
    SELECT pxtran, messageid FROM legs
    WHERE code IN ('300/04/05','300/04/06','606/06/05','606/06/06')
    GROUP BY pxtran, messageid
),
wm AS (
    SELECT l.pxtran, l.messageid, MAX(l.sku) AS sku,
           SUM(CASE WHEN LEFT(l.code,3)='300' THEN l.sqty ELSE 0 END) AS wm_active,
           SUM(CASE WHEN LEFT(l.code,3)='606' THEN l.sqty ELSE 0 END) AS wm_lock,
           MAX(l.has50) AS has50
    FROM legs l JOIN tx ON tx.pxtran = l.pxtran AND tx.messageid = l.messageid
    GROUP BY l.pxtran, l.messageid
),
d365 AS (
    SELECT l.pxtran, l.messageid,
           SUM(CASE WHEN ISNULL(d.wmslocationid,'') IN ('','Active') THEN CAST(p.qty AS int) ELSE 0 END) AS d_active,
           SUM(CASE WHEN ISNULL(d.wmslocationid,'') NOT IN ('','Active') THEN CAST(p.qty AS int) ELSE 0 END) AS d_lock,
           MIN(CAST(p.processed AS int)) AS all_processed
    FROM legs l
    JOIN pacwmpendingadjustment p ON p.integrationlinerecid = l.recid
    JOIN inventdim d ON d.inventdimid = p.inventdimid
    GROUP BY l.pxtran, l.messageid
)
SELECT w.pxtran, w.messageid AS pix_file, w.sku,
       CASE WHEN w.has50 = 1 THEN 'new (49+50)' ELSE 'old' END AS layout,
       w.wm_active, ISNULL(x.d_active,0) AS d365_active, w.wm_lock, ISNULL(x.d_lock,0) AS d365_lock,
       x.all_processed
FROM wm w LEFT JOIN d365 x ON x.pxtran = w.pxtran AND x.messageid = w.messageid
WHERE NOT (ISNULL(x.d_active,0) = w.wm_active AND ISNULL(x.d_lock,0) = w.wm_lock)
ORDER BY w.pxtran;
