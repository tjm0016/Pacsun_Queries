-- Every ASN hold/cancel row and every processing error log entry for vendor 856 messages since a date (UTC).
-- The error log holds the full infolog, including failures that write no ASN error row (e.g. "Purchase order line not found"
-- on a released ASN). notificationsent = 1 when the duplicate carton email went out.
SELECT 'error row' AS source, m.messageid, m.messagestatus, e.createddatetime, e.errortype, e.errorcode, e.releasehold,
       e.senttotraverse, e.notificationsent, e.purchid, e.asnid, CAST(e.errordescription AS varchar(600)) AS text_
FROM pacasnerrortable e
LEFT JOIN pacintopentextmessage m ON m.recid = e.message AND ISNULL(m.IsDelete, 0) = 0
WHERE ISNULL(e.IsDelete, 0) = 0 AND e.createddatetime >= '2026-10-22T14:00:00'
UNION ALL
SELECT 'error log', m.messageid, m.messagestatus, l.createddatetime, NULL, NULL, NULL, NULL, NULL, NULL, NULL, CAST(l.errortext AS varchar(2000))
FROM pacintopentextmessageerrorlog l
JOIN pacintopentextmessage m ON m.recid = l.message AND ISNULL(m.IsDelete, 0) = 0
JOIN sunintentitysetup s ON s.entityid = m.entityid AND ISNULL(s.IsDelete, 0) = 0 AND s.entityname = 'OpenText vendor 856'
WHERE ISNULL(l.IsDelete, 0) = 0 AND l.createddatetime >= '2026-10-22T14:00:00'
ORDER BY 4, 2, 1
