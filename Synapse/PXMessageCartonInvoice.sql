---Join Header and Line Table-----
WITH CartonHeader AS (
    SELECT 
        m.messageid AS HeaderID,     
        h.o3casn AS CartonNumber,
        m.statusdatetime AS HeaderFinishTime,
        m.createddatetime AS HeaderCreatedTime  
    FROM sunIntMessage m
    INNER JOIN sunIntEntitySetup s ON m.entityid = s.entityid
    INNER JOIN pacWMInvoiceCartonHeaderMessage h ON h.message = m.recid
    WHERE s.entityname = 'WM Invoice carton header'
      AND h.o3casn = '00060509838436'
),
CartonLine AS (
    SELECT 
        m.messageid AS LineID,    
        l.o4casn AS CartonNumber, 
        m.statusdatetime AS LineFinishTime,
        m.createddatetime AS LineCreatedTime 
    FROM sunIntMessage m
    INNER JOIN sunIntEntitySetup s ON m.entityid = s.entityid
    INNER JOIN pacWMInvoiceCartonLineMessage l ON l.message = m.recid
    WHERE s.entityname = 'WM Invoice carton line'
      AND l.o4casn = '00060509838436'
)

-- Join the CTEs and apply the PST conversion & formatting
SELECT 
    h.HeaderID,
    l.LineID,
    h.CartonNumber,
    
    -- Format Header Dates
    FORMAT(
        h.HeaderCreatedTime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 
        'M/dd/yyyy H:mm:ss'
    ) AS [Header Created Time (PST)],

    FORMAT(
        h.HeaderFinishTime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 
        'M/dd/yyyy H:mm:ss'
    ) AS [Header Finish Time (PST)],

    -- Format Line Dates
    FORMAT(
        l.LineCreatedTime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 
        'M/dd/yyyy H:mm:ss'
    ) AS [Line Created Time (PST)],

    FORMAT(
        l.LineFinishTime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 
        'M/dd/yyyy H:mm:ss'
    ) AS [Line Finish Time (PST)]

FROM CartonHeader h
INNER JOIN CartonLine l 
    ON h.CartonNumber = l.CartonNumber;
---Carton Line Only------------------------------------------------
SELECT TOP 5
    m.messageid AS [Line ID],    
    h.o4casn AS [Carton Number], 
   m.statusdatetime AS [Line Finish Time],
   m.createddatetime AS [Line Created Time] FROM 
    sunIntMessage m
INNER JOIN 
    sunIntEntitySetup s 
    ON m.entityid = s.entityid
INNER JOIN 
    pacWMInvoiceCartonLineMessage h
    ON h.message = m.recid
WHERE 
    s.entityname = 'WM Invoice carton line'
    AND h.o4casn = '00060509826785'
---Carton Header Only------------------------------------------------
SELECT TOP 5
    m.messageid AS [Header ID],     
    h.o3casn AS [Carton Number],
    m.statusdatetime AS [Header Finish Time],
    m.createddatetime AS [Header Created Time]  
    FROM 
    sunIntMessage m
INNER JOIN 
    sunIntEntitySetup s 
    ON m.entityid = s.entityid
INNER JOIN 
    pacWMInvoiceCartonHeaderMessage h
    ON h.message = m.recid
WHERE 
    s.entityname = 'WM Invoice carton header'
    AND h.o3casn = '00060509826785'
