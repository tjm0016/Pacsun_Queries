/* Item detail: 8/18 SKUs that hit 505000 with ZERO net unit change chain-wide */
WITH gl AS (
    SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000' AND gje.accountingdate = '2026-08-18'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
),
l AS (
    SELECT it.itemid COLLATE DATABASE_DEFAULT AS itemid, it.qty, it.costamountphysical,
           dim.inventlocationid COLLATE DATABASE_DEFAULT AS wh,
           dim.wmslocationid COLLATE DATABASE_DEFAULT AS bucket
    FROM gl
    JOIN dbo.inventtrans it ON it.voucherphysical COLLATE DATABASE_DEFAULT = gl.voucher
    LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = it.inventdimid COLLATE DATABASE_DEFAULT
),
byitem AS (SELECT itemid, SUM(qty) net_qty, SUM(-costamountphysical) net_505000 FROM l GROUP BY itemid)
SELECT b.itemid, b.net_qty, b.net_505000,
       SUM(CASE WHEN l.qty>0 THEN l.qty ELSE 0 END)                                 AS units_received,
       SUM(CASE WHEN l.qty>0 THEN -l.costamountphysical ELSE 0 END)                  AS cost_received,
       SUM(CASE WHEN l.qty<0 THEN -l.qty ELSE 0 END)                                 AS units_issued,
       SUM(CASE WHEN l.qty<0 THEN -l.costamountphysical ELSE 0 END)                  AS cost_issued,
       CASE WHEN SUM(CASE WHEN l.qty>0 THEN l.qty ELSE 0 END)=0 THEN NULL
            ELSE -SUM(CASE WHEN l.qty>0 THEN l.costamountphysical ELSE 0 END)/SUM(CASE WHEN l.qty>0 THEN l.qty ELSE 0 END) END AS unitcost_in,
       CASE WHEN SUM(CASE WHEN l.qty<0 THEN -l.qty ELSE 0 END)=0 THEN NULL
            ELSE SUM(CASE WHEN l.qty<0 THEN -l.costamountphysical ELSE 0 END)/SUM(CASE WHEN l.qty<0 THEN -l.qty ELSE 0 END) END AS unitcost_out
FROM byitem b JOIN l ON l.itemid = b.itemid
WHERE ABS(b.net_qty) < 0.5 AND ABS(b.net_505000) > 0.005
GROUP BY b.itemid, b.net_qty, b.net_505000
ORDER BY ABS(b.net_505000) DESC;
