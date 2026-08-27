/* Same split, 8/11-8/19: is "shrink from SKUs that didn't move" chronic or new? */
WITH gl AS (
    SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher,
           CAST(gje.accountingdate AS date) AS acctdate
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000'
      AND gje.accountingdate >= '2026-08-11' AND gje.accountingdate < '2026-08-20'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
),
byitem AS (
    SELECT gl.acctdate, it.itemid COLLATE DATABASE_DEFAULT AS itemid,
           SUM(it.qty) AS net_qty, SUM(-it.costamountphysical) AS net_505000
    FROM gl
    JOIN dbo.inventtrans it ON it.voucherphysical COLLATE DATABASE_DEFAULT = gl.voucher
    GROUP BY gl.acctdate, it.itemid COLLATE DATABASE_DEFAULT
)
SELECT acctdate,
       SUM(CASE WHEN ABS(net_qty) < 0.5 THEN net_505000 ELSE 0 END) AS amt_from_zero_net_unit_skus,
       SUM(CASE WHEN ABS(net_qty) >= 0.5 THEN net_505000 ELSE 0 END) AS amt_from_real_unit_change,
       SUM(net_505000) AS total_505000,
       SUM(CASE WHEN ABS(net_qty) < 0.5 THEN 1 ELSE 0 END) AS skus_zero_net,
       SUM(CASE WHEN ABS(net_qty) >= 0.5 THEN 1 ELSE 0 END) AS skus_moved
FROM byitem GROUP BY acctdate ORDER BY 1;
