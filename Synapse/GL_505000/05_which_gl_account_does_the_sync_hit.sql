/* Which GL account did last night's COU-DCSYNC journals actually hit? */
WITH v AS (
  SELECT DISTINCT t.voucher COLLATE DATABASE_DEFAULT AS voucher
  FROM dbo.inventjournaltable jt
  JOIN dbo.inventjournaltrans t ON t.journalid COLLATE DATABASE_DEFAULT = jt.journalid COLLATE DATABASE_DEFAULT
  WHERE jt.journalnameid = 'COU-DCSYNC' AND t.transdate >= '2026-08-16' AND t.transdate < '2026-08-19'
)
SELECT CAST(gje.accountingdate AS date) AS acctdate,
       ma.mainaccountid, gjae.ledgeraccount, gjae.postingtype,
       COUNT(*) AS lines, SUM(gjae.accountingcurrencyamount) AS amt
FROM v
JOIN dbo.generaljournalentry gje ON gje.subledgervoucher COLLATE DATABASE_DEFAULT = v.voucher
JOIN dbo.generaljournalaccountentry gjae ON gjae.generaljournalentry = gje.recid
JOIN dbo.mainaccount ma ON ma.recid = gjae.mainaccount
GROUP BY CAST(gje.accountingdate AS date), ma.mainaccountid, gjae.ledgeraccount, gjae.postingtype
ORDER BY 1, ABS(SUM(gjae.accountingcurrencyamount)) DESC;
