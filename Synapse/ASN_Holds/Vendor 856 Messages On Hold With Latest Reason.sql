-- Every vendor 856 message currently on hold (status 30) with its newest ASN error row and newest processing error log text.
-- A blank error row with log text "Duplicate cartons exist ..." is the pre-10/22 mixed-carton false positive; Reprocess it.
WITH held AS (
  SELECT m.recid, m.messageid, m.createddatetime, m.statusdatetime
  FROM pacintopentextmessage m
  JOIN sunintentitysetup s ON s.entityid = m.entityid AND ISNULL(s.IsDelete,0) = 0 AND s.entityname = 'OpenText vendor 856'
  WHERE ISNULL(m.IsDelete,0) = 0 AND m.messagestatus = 30
), er AS (
  SELECT e.message, e.errortype, e.errorcode, e.releasehold, e.purchid, CAST(e.errordescription AS varchar(400)) AS descr, e.createddatetime,
         ROW_NUMBER() OVER (PARTITION BY e.message ORDER BY e.createddatetime DESC, e.recid DESC) AS rn,
         COUNT(*) OVER (PARTITION BY e.message) AS nrows
  FROM pacasnerrortable e WHERE ISNULL(e.IsDelete,0) = 0
), lg AS (
  SELECT l.message, CAST(l.errortext AS varchar(600)) AS logtext, l.createddatetime,
         ROW_NUMBER() OVER (PARTITION BY l.message ORDER BY l.createddatetime DESC, l.recid DESC) AS rn
  FROM pacintopentextmessageerrorlog l WHERE ISNULL(l.IsDelete,0) = 0
)
SELECT h.messageid, h.createddatetime, h.statusdatetime, er.errortype, er.errorcode, er.releasehold, er.purchid, er.nrows, er.createddatetime AS err_dt, er.descr,
       lg.createddatetime AS log_dt, lg.logtext
FROM held h
LEFT JOIN er ON er.message = h.recid AND er.rn = 1
LEFT JOIN lg ON lg.message = h.recid AND lg.rn = 1
ORDER BY h.createddatetime
