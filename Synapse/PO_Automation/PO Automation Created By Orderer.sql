-- PO Automation: POs / lines / units created, by orderer
-- Source: D365 prod Synapse (dataverse_psprod). Automation POs = created by svc_d365batch
-- with a real orderer (the batch service's own default orderer is 000011).
-- Shows CURRENT D365 state: deleted POs are gone, canceled POs keep their lines but qty = 0.
-- Date range is in PACIFIC time, inclusive of both days. Automation went live 2026-10-13.
DECLARE @FromDate date = '2026-10-13';
DECLARE @ToDate   date = '2026-10-22';
-- createddatetime is stored in UTC; convert the PT day boundaries to UTC.
DECLARE @FromUtc datetime2 = CAST(CAST(@FromDate AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC' AS datetime2);
DECLARE @ToUtc   datetime2 = CAST(CAST(DATEADD(day, 1, @ToDate) AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC' AS datetime2);

WITH po AS (
    SELECT t.purchid, t.purchstatus, t.workerpurchplacer
    FROM purchtable t
    JOIN hcmworker w ON w.recid = t.workerpurchplacer
    WHERE t.dataareaid = '1001'
      AND ISNULL(t.IsDelete, 0) = 0
      AND t.createdby = 'svc_d365batch'
      AND w.personnelnumber <> '000011'
      AND t.createddatetime >= @FromUtc
      AND t.createddatetime <  @ToUtc
),
ln AS (
    SELECT l.purchid, COUNT(*) AS lines, SUM(l.purchqty) AS units
    FROM purchline l
    JOIN po ON po.purchid = l.purchid
    WHERE l.dataareaid = '1001' AND ISNULL(l.IsDelete, 0) = 0
    GROUP BY l.purchid
)
SELECT ISNULL(d.name, w.personnelnumber)                       AS orderer,
       w.personnelnumber,
       COUNT(*)                                                 AS pos,
       SUM(ISNULL(ln.lines, 0))                                 AS lines,
       SUM(ISNULL(ln.units, 0))                                 AS units,
       SUM(CASE WHEN po.purchstatus <> 4 THEN 1 ELSE 0 END)     AS active_pos,
       SUM(CASE WHEN po.purchstatus = 4 THEN 1 ELSE 0 END)      AS canceled_pos
FROM po
JOIN hcmworker w      ON w.recid = po.workerpurchplacer
LEFT JOIN dirpartytable d ON d.recid = w.person
LEFT JOIN ln          ON ln.purchid = po.purchid
GROUP BY ISNULL(d.name, w.personnelnumber), w.personnelnumber
ORDER BY units DESC;
