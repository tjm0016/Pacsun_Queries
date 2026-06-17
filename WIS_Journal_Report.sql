SELECT
    ijt.journalid AS JournalID, 
    ijt.InventLocationId AS Warehouse,
    ijt.NumOfLines AS Lines,
    -- Format posted variable to text
    CASE 
        WHEN ijt.posted = 0 THEN 'No'
        WHEN ijt.posted = 1 THEN 'Yes'
    END AS Posted,
    ijt.createddatetime,
    -- Get Total On Hand (remove extra zeros)
    CAST(SUM(trans.InventOnHand) AS DECIMAL(18,2)) AS TotalInventOnHand,
    -- Get Total Cost of Journal (remove extra zeros)
    CAST(SUM(trans.costamount) AS DECIMAL(18,2)) AS TotalCostAmount,
    -- Get Total Counted by WIS (remove extra zeros)
    CAST(SUM(trans.Counted) AS DECIMAL(18,2)) AS TotalCounted,
    -- Calculate Cost Based on Item counted (remove extra zeros)
    CAST(
        SUM(trans.CostPrice * trans.Counted) AS DECIMAL(18,2)
    ) AS TotalCountedCost
-- Journal Header Table
FROM InventJournalTable ijt
-- Journal Line Table
JOIN InventJournalTrans trans
-- Join on JournalID
    ON ijt.journalid = trans.journalid
-- Filter for Warehouse Snapshot
WHERE ijt.JournalNameId = 'COU-INVSNAP'
-- Group By Journal
GROUP BY 
    ijt.journalid,
    ijt.InventLocationId,
    ijt.NumOfLines,
    ijt.posted,
    ijt.createddatetime
-- Michael Arthur --
ORDER BY ijt.createddatetime ASC;
