/* TEST 1: is 4901 300/01/22 (out) the same SKUs as 4905 300/01/99 (in)? */
WITH gl AS (
    SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000' AND gje.accountingdate = '2026-08-18'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
),
L AS (
    SELECT t.itemid COLLATE DATABASE_DEFAULT AS itemid,
           dim.inventsizeid COLLATE DATABASE_DEFAULT AS sz, dim.inventcolorid COLLATE DATABASE_DEFAULT AS cl,
           dim.inventlocationid COLLATE DATABASE_DEFAULT AS wh,
           t.pacwmpxtxtp COLLATE DATABASE_DEFAULT AS tp, t.pacwmpxtxcd COLLATE DATABASE_DEFAULT AS cd,
           t.pacwmpxaccd COLLATE DATABASE_DEFAULT AS ac,
           t.qty, t.costamount
    FROM gl JOIN dbo.inventjournaltrans t ON t.voucher COLLATE DATABASE_DEFAULT = gl.voucher
    LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = t.inventdimid COLLATE DATABASE_DEFAULT
),
out22 AS (SELECT itemid, sz, cl, SUM(qty) q, SUM(-costamount) amt FROM L WHERE wh='4901' AND tp='300' AND cd='01' AND ac='22' GROUP BY itemid, sz, cl),
in99  AS (SELECT itemid, sz, cl, SUM(qty) q, SUM(-costamount) amt FROM L WHERE wh='4905' AND tp='300' AND cd='01' AND ac='99' GROUP BY itemid, sz, cl)
SELECT
  (SELECT COUNT(*) FROM out22)                                       AS keys_4901_22,
  (SELECT COUNT(*) FROM in99)                                        AS keys_4905_99,
  (SELECT COUNT(*) FROM out22 o JOIN in99 i ON o.itemid=i.itemid AND o.sz=i.sz AND o.cl=i.cl) AS keys_matched,
  (SELECT COUNT(*) FROM out22 o JOIN in99 i ON o.itemid=i.itemid AND o.sz=i.sz AND o.cl=i.cl AND ABS(o.q + i.q) < 0.5) AS keys_qty_exact_offset,
  (SELECT SUM(o.q) FROM out22 o JOIN in99 i ON o.itemid=i.itemid AND o.sz=i.sz AND o.cl=i.cl) AS matched_qty_out,
  (SELECT SUM(i.q) FROM out22 o JOIN in99 i ON o.itemid=i.itemid AND o.sz=i.sz AND o.cl=i.cl) AS matched_qty_in,
  (SELECT SUM(o.amt + i.amt) FROM out22 o JOIN in99 i ON o.itemid=i.itemid AND o.sz=i.sz AND o.cl=i.cl) AS matched_net_dollars;

/* TEST 2: the lock/unlock wash at 4901 - qty nets to zero, dollars do not. Top items. */
WITH gl AS (
    SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000' AND gje.accountingdate = '2026-08-18'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
)
SELECT TOP 15
       t.itemid, dim.inventlocationid AS wh, dim.inventsizeid AS sz, dim.inventcolorid AS cl,
       SUM(t.qty) AS net_qty, SUM(-t.costamount) AS net_505000,
       SUM(CASE WHEN t.qty > 0 THEN t.qty ELSE 0 END) AS qty_in,
       SUM(CASE WHEN t.qty > 0 THEN -t.costamount ELSE 0 END) AS amt_in,
       SUM(CASE WHEN t.qty < 0 THEN t.qty ELSE 0 END) AS qty_out,
       SUM(CASE WHEN t.qty < 0 THEN -t.costamount ELSE 0 END) AS amt_out
FROM gl JOIN dbo.inventjournaltrans t ON t.voucher COLLATE DATABASE_DEFAULT = gl.voucher
LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = t.inventdimid COLLATE DATABASE_DEFAULT
WHERE t.pacwmpxaccd COLLATE DATABASE_DEFAULT IN ('05','06','19','20')
GROUP BY t.itemid, dim.inventlocationid, dim.inventsizeid, dim.inventcolorid
HAVING ABS(SUM(t.qty)) < 0.5 AND ABS(SUM(-t.costamount)) > 200
ORDER BY ABS(SUM(-t.costamount)) DESC;
