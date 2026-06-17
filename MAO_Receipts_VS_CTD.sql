WITH ReceiptData AS (
    SELECT 
-- Remove leading zeros from carton numbers in MAO workspace
        CASE 
            WHEN CartonNumber NOT LIKE '%[^0]%' THEN '0'
            WHEN CartonNumber LIKE '%[^0-9]%' THEN CartonNumber
            ELSE STUFF(CartonNumber, 1, PATINDEX('%[^0]%', CartonNumber) - 1, '')
        END AS CleanCartonNumber,
        storereceiptstatus
    FROM pacIntMAOStoreReceipt
),
TransferData AS (
    SELECT 
-- Remove leading zeros from carton numbers in CTD
        CASE 
            WHEN CartonNumber NOT LIKE '%[^0]%' THEN '0'
            WHEN CartonNumber LIKE '%[^0-9]%' THEN CartonNumber
            ELSE STUFF(CartonNumber, 1, PATINDEX('%[^0]%', CartonNumber) - 1, '')
        END AS CleanCartonNumber,
-- Format Carton Status to Char
        CASE
            WHEN cartonstatus = 0 THEN 'Created'
            WHEN cartonstatus = 1 THEN 'In-transit'
            WHEN cartonstatus = 2 THEN 'POD, not acknowledged'
            WHEN cartonstatus = 3 THEN 'Acknowledged'
            WHEN cartonstatus = 4 THEN 'Complete'
        END AS CartonStatusName,
        cartonstatus AS RawCartonStatus
    FROM PacCartonTransferHeader
)
SELECT 
    COALESCE(R.CleanCartonNumber, T.CleanCartonNumber) AS CartonNumber,
    R.storereceiptstatus AS StoreReceiptStatus,
    T.CartonStatusName AS TransferStatus,
-- Create Mismatch column
    CASE 
        WHEN R.CleanCartonNumber IS NOT NULL AND T.CleanCartonNumber IS NOT NULL THEN 'Match'
        ELSE 'No Match'
    END AS MatchOrNot
FROM ReceiptData R
FULL OUTER JOIN TransferData T 
    ON R.CleanCartonNumber = T.CleanCartonNumber
-- Check carton status
-- Michael Arthur --
WHERE
    NOT (
        ISNULL(R.storereceiptstatus, 'Received') = 'Received' 
        AND ISNULL(T.RawCartonStatus, 4) = 4
    );
