SELECT TOP 5 
    p.PXPON, m.messageid, m.MessageStatus
FROM pacWMPIXMessage p
INNER JOIN sunIntMessage m 
    ON p.message = m.recid
WHERE p.PXPON LIKE '%768233'
AND m.messageid like '%ASNReceipt%'
-- error = 30
-- processed = 40
