-- When did WM send the dock appointment for a PO?
-- PO lines -> arrival journal (ASN off the header) -> PIX 611 appointment message on that ASN.
-- pxdcr/pxtcr = when WM created the transaction (WM local time); pxref3 = appointment WM sent (CCYYMMDDHHMMSS);
-- pxref2 = appointment number; msg_created/msg_processed = when D365 received/processed it (UTC).
-- A 04:44 or 00:00 appointment time is usually a default, not a real dock slot.
DECLARE @po varchar(10) = '0001517648';   -- zero-padded 10 chars

WITH asn AS (
    SELECT DISTINCT h.journalid, h.pacasnid, h.pacappointmentdate, h.pacarrivaldate, h.posted, h.posteddatetime
    FROM wmsjournaltable h
    JOIN wmsjournaltrans t ON t.journalid = h.journalid AND t.dataareaid = h.dataareaid
    WHERE t.inventtransrefid = @po AND h.dataareaid = '1001'
)
SELECT a.journalid,
       a.pacasnid,
       a.pacappointmentdate                       AS d365_appointment,
       a.pacarrivaldate,
       a.posted,
       p.pxtxtp + '-' + p.pxtxcd                  AS pix_type,
       RIGHT(p.pxdcr, 8) + ' ' + RIGHT(p.pxtcr, 6) AS wm_created_yyyymmdd_hhmmss,
       p.pxref2                                   AS appointment_no,
       p.pxref3                                   AS appointment_sent,
       m.messageid,
       m.messagestatus,
       m.createddatetime                          AS msg_created_utc,
       m.statusdatetime                           AS msg_processed_utc
FROM asn a
LEFT JOIN pacwmpixmessage p ON p.pxshmt = a.pacasnid AND p.pxtxtp = '611' AND p.dataareaid = '1001'
LEFT JOIN sunintmessage  m ON m.recid = p.message
ORDER BY a.journalid, m.createddatetime;
