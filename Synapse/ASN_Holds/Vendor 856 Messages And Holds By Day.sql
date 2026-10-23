-- Vendor 856 (OpenText) messages per Pacific day by status, and ASN hold/cancel rows per Pacific day by error type.
-- Status: 30 = on hold, 40 = processed, 50 = cancelled. Error type: 0 overage, 1 shortage, 5 items missing, 6 item not on PO,
-- 7 PO under revision, 8 line closed, 9/10 duplicate ASN, 16 duplicate carton, 17 auto-cancelled exact copy, 18 auto-cancelled manual receipt match.
-- Hours: UTC-7 (PDT). Change the start date as needed.
SELECT 'message' AS kind, CAST(DATEADD(hour, -7, m.createddatetime) AS date) AS pt_day, CAST(m.messagestatus AS varchar(10)) AS k, COUNT(*) AS n
FROM pacintopentextmessage m
JOIN sunintentitysetup s ON s.entityid = m.entityid AND ISNULL(s.IsDelete, 0) = 0 AND s.entityname = 'OpenText vendor 856'
WHERE ISNULL(m.IsDelete, 0) = 0 AND m.createddatetime >= '2026-10-22T14:00:00'
GROUP BY CAST(DATEADD(hour, -7, m.createddatetime) AS date), m.messagestatus
UNION ALL
SELECT 'error row', CAST(DATEADD(hour, -7, e.createddatetime) AS date), CAST(e.errortype AS varchar(10)), COUNT(*)
FROM pacasnerrortable e
WHERE ISNULL(e.IsDelete, 0) = 0 AND e.createddatetime >= '2026-10-22T14:00:00'
GROUP BY CAST(DATEADD(hour, -7, e.createddatetime) AS date), e.errortype
ORDER BY 1, 2, 3
