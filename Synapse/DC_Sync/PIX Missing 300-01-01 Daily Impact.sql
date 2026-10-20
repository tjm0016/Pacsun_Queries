/* Missing PIX 300/01/01 mapping - daily impact at 4905
   WM sends "create case" as one pxtran: a subtract leg (300/04 blank from Active, or 606/06 from a
   lock code) + a 300/01/01 'A' add leg. The A leg has no row in pacwmpixtransactionmappingtable, so
   only the subtract posts. Each row = the units/$ D365 under-booked that day (what the A leg would
   have added back). Day = MOV-DCADJ journal created date, Pacific. Set @d1/@d2. */
DECLARE @d1 date = '2026-09-01', @d2 date = '2026-10-20';

WITH a AS (
    SELECT DISTINCT pxtran
    FROM dbo.pacwmpixmessage
    WHERE createddatetime >= DATEADD(day, -2, CAST(@d1 AS datetime2))
      AND pxtxtp = '300' AND pxtxcd = '01' AND pxaccd = '01' AND pxinat = 'A'
)
SELECT CONVERT(varchar(10), j.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 23) AS day_pt,
       COUNT(*)                                                   AS phantom_lines,
       COUNT(DISTINCT t.pacwmpxtran)                              AS pxtrans,
       SUM(CASE WHEN d.wmslocationid = 'Active' THEN t.qty ELSE 0 END)    AS active_qty,
       SUM(CASE WHEN d.wmslocationid = 'Lock_Code' THEN t.qty ELSE 0 END) AS lock_qty,
       SUM(t.qty)                                                 AS phantom_qty,
       CAST(SUM(t.costamount) AS decimal(14,2))                   AS phantom_cost
FROM dbo.inventjournaltrans t
JOIN dbo.inventjournaltable j ON j.journalid = t.journalid
JOIN dbo.inventdim d          ON d.inventdimid = t.inventdimid
JOIN a                        ON a.pxtran = t.pacwmpxtran
WHERE j.journalnameid = 'MOV-DCADJ'
  AND d.inventlocationid = '4905'
  AND j.createddatetime >= DATEADD(hour, 7, CAST(@d1 AS datetime2))                    -- PT midnight (PDT) in UTC
  AND j.createddatetime <  DATEADD(hour, 7, CAST(DATEADD(day, 1, @d2) AS datetime2))
  AND ( (t.pacwmpxtxtp = '300' AND t.pacwmpxtxcd = '04' AND ISNULL(t.pacwmpxaccd, '') = '')
     OR (t.pacwmpxtxtp = '606' AND t.pacwmpxtxcd = '06') )
GROUP BY CONVERT(varchar(10), j.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 23)
ORDER BY day_pt;
