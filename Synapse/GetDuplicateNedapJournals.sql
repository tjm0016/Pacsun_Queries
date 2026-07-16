SELECT 
trans.journalid AS Journal,
dim.InventLocationId AS Warehouse,
ijt.NumOfLines AS TotalLinesInJournal,
  CASE ijt.pacThresholdCheck
    WHEN 0 THEN 'None'
    WHEN 1 THEN 'Error'
    WHEN 2 THEN 'Success'
  END AS Threshold,
  CASE
    WHEN ijt.posted = 0 THEN 'No'
    WHEN ijt.posted = 1 THEN 'Yes' 
  END AS Posted,
  FORMAT(ijt.createddatetime, 'MM/dd/yyyy') AS CreatedDate,
    CAST(SUM(trans.qty) AS DECIMAL(18, 2)) AS TotalQuantity,
    CAST(SUM(trans.costamount) AS DECIMAL(18, 2)) AS TotalCostAmount,
    CAST(SUM(trans.costprice) AS DECIMAL(18, 2)) AS TotalCostPrice 
FROM InventJournalTrans trans 
  JOIN InventDim dim
ON trans.InventDimId = dim.InventDimId
  JOIN InventJournalTable ijt
ON trans.journalid = ijt.journalid
  WHERE ijt.journalnameid = 'MOV-RFID'
  --- ADD CORRECT DATE ---
AND ijt.createddatetime LIKE '2026-05-18%'AND ijt.posted = 1
  GROUP BY 
    trans.journalid, dim.InventLocationId, ijt.NumOfLines, ijt.pacThresholdCheck, ijt.posted,
    FORMAT(ijt.createddatetime, 'MM/dd/yyyy')
    ORDER BY dim.InventLocationId ASC;
