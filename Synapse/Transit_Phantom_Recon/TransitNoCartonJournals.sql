-- Journals that post to -T warehouses with NO carton number (go-live MOV-MIG lumps, 7/15 dup-carton fix,
-- 8/1 transit write-off, donations, manual adjustments). As of 2026-10-05 they net +475,207 units at -T and
-- are offset by -474,832 on carton-numbered receipts (pre-go-live cartons received after go-live), so they
-- cancel by warehouse total but break any carton-level InventTrans-vs-carton join.
SELECT o.referenceid COLLATE DATABASE_DEFAULT AS journalid, jt.journalnameid, jt.description, jt.journaltype,
       jt.paccartonreasoncode AS rc, jt.createdby, jt.createddatetime, jt.posteddatetime,
       MIN(t.datephysical) AS dphys_min, MAX(t.datephysical) AS dphys_max,
       COUNT(DISTINCT d.inventlocationid) AS n_twh,
       SUM(CASE WHEN t.qty > 0 THEN t.qty ELSE 0 END) AS qty_in,
       SUM(CASE WHEN t.qty < 0 THEN t.qty ELSE 0 END) AS qty_out,
       SUM(t.qty) AS net
FROM inventtrans t
JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
JOIN inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = o.referenceid COLLATE DATABASE_DEFAULT
     AND jt.dataareaid = '1001' AND ISNULL(jt.IsDelete,0)=0
WHERE t.dataareaid='1001' AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
  AND d.inventlocationid LIKE '%-T'
  AND (t.statusreceipt IN (1,2) OR t.statusissue IN (1,2))
  AND (jt.paccartontransfernumber IS NULL OR jt.paccartontransfernumber = '')
GROUP BY o.referenceid, jt.journalnameid, jt.description, jt.journaltype, jt.paccartonreasoncode, jt.createdby,
         jt.createddatetime, jt.posteddatetime
