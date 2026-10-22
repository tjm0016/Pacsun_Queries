-- PO Automation: estimated manual-entry time saved, by orderer
-- Minutes per PO = 2 + 0.5 x (lines - 1), capped at 12.
-- Same PO population as "PO Automation Created By Orderer.sql" (current D365 state).
-- Date range is in PACIFIC time, inclusive of both days. Automation went live 2026-10-13.
DECLARE @FromDate date = '2026-10-13';
DECLARE @ToDate   date = '2026-10-22';
-- createddatetime is stored in UTC; convert the PT day boundaries to UTC.
DECLARE @FromUtc datetime2 = CAST(CAST(@FromDate AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC' AS datetime2);
DECLARE @ToUtc   datetime2 = CAST(CAST(DATEADD(day, 1, @ToDate) AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC' AS datetime2);
DECLARE @BaseMin   decimal(9,2) = 2.0;   -- 1-line PO
DECLARE @PerLine   decimal(9,2) = 0.5;   -- each additional line
DECLARE @CapMin    decimal(9,2) = 12.0;  -- max per PO

WITH po AS (
    SELECT t.purchid, t.workerpurchplacer
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
    SELECT po.purchid, po.workerpurchplacer,
           (SELECT COUNT(*) FROM purchline l
             WHERE l.purchid = po.purchid AND l.dataareaid = '1001'
               AND ISNULL(l.IsDelete, 0) = 0) AS lines
    FROM po
),
est AS (
    SELECT ln.*,
           CASE WHEN @BaseMin + @PerLine * (lines - 1) > @CapMin THEN @CapMin
                ELSE @BaseMin + @PerLine * (lines - 1) END AS est_min
    FROM ln
)
SELECT ISNULL(d.name, w.personnelnumber)          AS orderer,
       COUNT(*)                                    AS pos,
       SUM(est.lines)                              AS lines,
       SUM(est.est_min)                            AS est_minutes,
       CAST(SUM(est.est_min) / 60.0 AS decimal(9,1))   AS est_hours,
       CAST(AVG(est.est_min) AS decimal(9,1))          AS avg_min_per_po
FROM est
JOIN hcmworker w      ON w.recid = est.workerpurchplacer
LEFT JOIN dirpartytable d ON d.recid = w.person
GROUP BY ISNULL(d.name, w.personnelnumber)
ORDER BY est_minutes DESC;
