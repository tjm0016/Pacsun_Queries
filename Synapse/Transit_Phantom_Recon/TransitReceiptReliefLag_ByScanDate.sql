-- Store carton receipts by store scan date (PT) vs. the date InventTrans relieves the -T warehouse.
-- Weekdays: ~85-93% of receipt units leave -T the NEXT day (Carton Receive batch starts ~11:21 PM PT;
-- journals posted after midnight carry the next date). Weekends: all same day. Validated 2026-10-05 for
-- 8/14-8/22/2026 (e.g. Mon 8/17: 12,361 same day / 172,763 next day). Pairs with TransitReceiveJournalLag.sql.
DECLARE @from date = '2026-08-14', @to date = '2026-08-22';
WITH rcv AS (
  SELECT h.cartonnumber COLLATE DATABASE_DEFAULT AS cartonnumber,
         CAST(h.receiveddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS date) AS scan_date_pt
  FROM paccartontransferheader h
  WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0
    AND h.receiveddatetime >= @from AND h.receiveddatetime < DATEADD(day, 2, @to)
),
leg AS (
  SELECT j.paccartontransfernumber COLLATE DATABASE_DEFAULT AS cartonnumber,
         MIN(t.datephysical) AS relief_date, SUM(-t.qty) AS units
  FROM inventjournaltable j
  JOIN inventtransorigin o ON o.referenceid COLLATE DATABASE_DEFAULT = j.journalid COLLATE DATABASE_DEFAULT
       AND o.dataareaid = j.dataareaid AND ISNULL(o.IsDelete,0) = 0
  JOIN inventtrans t ON t.inventtransorigin = o.recid AND t.partition = o.partition AND ISNULL(t.IsDelete,0) = 0
  JOIN inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid = t.dataareaid AND d.partition = t.partition
  WHERE j.dataareaid = '1001' AND ISNULL(j.IsDelete,0) = 0
    AND j.journalnameid = 'CTN-TRANSFER' AND j.paccartonreasoncode = 2 AND j.posted = 1
    AND j.createddatetime >= @from AND j.createddatetime < DATEADD(day, 3, @to)
    AND d.inventlocationid LIKE '%-T' AND t.qty < 0
  GROUP BY j.paccartontransfernumber
)
SELECT r.scan_date_pt, DATENAME(weekday, r.scan_date_pt) AS scan_dow,
       SUM(CASE WHEN l.relief_date = r.scan_date_pt THEN l.units ELSE 0 END) AS units_relieved_same_day,
       SUM(CASE WHEN l.relief_date > r.scan_date_pt THEN l.units ELSE 0 END) AS units_relieved_later,
       SUM(CASE WHEN l.relief_date < r.scan_date_pt THEN l.units ELSE 0 END) AS units_relieved_earlier,
       COUNT(CASE WHEN l.cartonnumber IS NULL THEN 1 END) AS cartons_no_relief_found
FROM rcv r
LEFT JOIN leg l ON l.cartonnumber = r.cartonnumber
WHERE r.scan_date_pt BETWEEN @from AND @to
GROUP BY r.scan_date_pt
ORDER BY r.scan_date_pt;
