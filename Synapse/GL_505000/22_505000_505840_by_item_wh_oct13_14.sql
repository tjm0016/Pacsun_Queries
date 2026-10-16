/* 505000/505840 by item + warehouse, 10/13-10/14/2026. net = -costamountphysical, + = loss */
WITH gl AS (
  SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher, ma.mainaccountid COLLATE DATABASE_DEFAULT AS acct, CAST(gje.accountingdate AS date) d
  FROM dbo.mainaccount ma
  JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
  JOIN dbo.generaljournalentry gje ON gje.recid = gjae.generaljournalentry
  WHERE ma.mainaccountid IN ('505000','505840') AND gje.accountingdate >= '2026-10-13' AND gje.accountingdate < '2026-10-15'
    AND gjae.postingtype IN (93,94)
)
SELECT gl.acct, gl.d, it.itemid COLLATE DATABASE_DEFAULT itemid, dim.inventlocationid COLLATE DATABASE_DEFAULT wh,
  SUM(CASE WHEN it.qty<0 THEN -it.qty ELSE 0 END) u_out, SUM(CASE WHEN it.qty<0 THEN -it.costamountphysical ELSE 0 END) c_out,
  SUM(CASE WHEN it.qty>0 THEN it.qty ELSE 0 END) u_in, SUM(CASE WHEN it.qty>0 THEN it.costamountphysical ELSE 0 END) c_in,
  SUM(-it.costamountphysical) net
FROM gl JOIN dbo.inventtrans it ON it.voucherphysical COLLATE DATABASE_DEFAULT = gl.voucher
LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = it.inventdimid COLLATE DATABASE_DEFAULT
GROUP BY gl.acct, gl.d, it.itemid COLLATE DATABASE_DEFAULT, dim.inventlocationid COLLATE DATABASE_DEFAULT;
