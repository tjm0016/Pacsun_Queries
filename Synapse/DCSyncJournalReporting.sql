SELECT
    ijt.journalid, 
    ijt.NumOfLines AS Lines, 
    CASE 
        WHEN ijt.posted = 0 THEN 'No'
        WHEN ijt.posted = 1 THEN 'Yes'
    END AS Posted,
    CONVERT(VARCHAR(10), ijt.createddatetime, 101) AS CreatedDate,
    CAST(SUM(trans.costamount) AS DECIMAL(18,2)) AS TotalCostAmount,
    CAST(SUM(trans.CostPrice) AS DECIMAL(18,2)) AS TotalCostPrice,
    CAST(SUM(trans.Counted) AS DECIMAL(18,2)) AS TotalCounted,
    CAST(SUM(trans.InventOnHand) AS DECIMAL(18,2)) AS TotalInventOnHand
FROM InventJournalTable ijt
JOIN InventJournalTrans trans
    ON ijt.journalid = trans.journalid
WHERE ijt.description = 'Daily inventory sync - Groveport'
GROUP BY 
    ijt.journalid,
    ijt.NumOfLines,
    ijt.posted,
    ijt.createddatetime;
