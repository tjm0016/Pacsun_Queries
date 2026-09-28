-- RFID SKU Detail By Store - posted MOV-RFID store RFID count journals, company 1001.
-- Date range = journal CREATED date in Pacific time (same basis as the original "RFID by Class By Store" file).
-- Class = leading segment of itemid ('0702' of '0702-60474-0013'). Journal Number on every row.
-- Same SQL the Store RFID Count Report web page runs (DailySyncPortal\api\shared\rfid.js).
-- Connection: Synapse (d365-synapse-ps-prod-ondemand / dataverse_psprod_...).
DECLARE @from date = '2026-09-21', @to date = '2026-09-27';
DECLARE @fromUtc datetime2 = CONVERT(datetime2, CAST(@from AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC');
DECLARE @toUtc   datetime2 = CONVERT(datetime2, CAST(DATEADD(day, 1, @to) AS datetime2) AT TIME ZONE 'Pacific Standard Time' AT TIME ZONE 'UTC');
WITH j AS (
  SELECT journalid, dataareaid, description, createddatetime
  FROM inventjournaltable
  WHERE journalnameid = 'MOV-RFID' AND dataareaid = '1001' AND posted = 1
    AND createddatetime >= @fromUtc AND createddatetime < @toUtc
), l AS (
  SELECT d.inventlocationid AS Store,
         LEFT(t.itemid, CHARINDEX('-', t.itemid + '-') - 1) AS Class,
         t.itemid, d.inventcolorid, d.inventsizeid,
         j.journalid, j.description,
         CONVERT(date, j.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS CreatedDate,
         t.qty, t.costamount
  FROM j
  JOIN inventjournaltrans t ON t.journalid = j.journalid AND t.dataareaid = j.dataareaid
  JOIN inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid = t.dataareaid
)
SELECT Store, Class, itemid AS ItemId, inventcolorid AS Color, inventsizeid AS Size,
       journalid AS JournalNumber, MAX(description) AS JournalDescription, MAX(CreatedDate) AS CreatedDate,
       COUNT(*) AS TotalLines,
       CAST(ROUND(SUM(qty), 2) AS decimal(19,2)) AS TotalQuantity, CAST(ROUND(SUM(costamount), 2) AS decimal(19,2)) AS TotalCostAmount,
       CAST(ROUND(SUM(costamount) / NULLIF(SUM(qty), 0), 2) AS decimal(19,2)) AS AverageCostPrice
FROM l
GROUP BY Store, Class, itemid, inventcolorid, inventsizeid, journalid
ORDER BY Store, Class, itemid, inventcolorid, inventsizeid, MAX(CreatedDate), journalid;
