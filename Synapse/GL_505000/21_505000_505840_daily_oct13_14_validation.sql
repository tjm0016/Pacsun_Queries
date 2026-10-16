/* 505000 + 505840 by day, DC dims split, 10/11-10/16/2026 (validating the ~$105.7k 10/13-14 hit) */
SELECT CAST(gje.accountingdate AS date) AS d, ma.mainaccountid COLLATE DATABASE_DEFAULT AS acct, gjae.postingtype,
  SUM(CASE WHEN SUBSTRING(gjae.ledgeraccount COLLATE DATABASE_DEFAULT,8,5)='14901' THEN gjae.accountingcurrencyamount ELSE 0 END) a4901,
  SUM(CASE WHEN SUBSTRING(gjae.ledgeraccount COLLATE DATABASE_DEFAULT,8,5)='74905' THEN gjae.accountingcurrencyamount ELSE 0 END) a4905,
  SUM(gjae.accountingcurrencyamount) total
FROM dbo.mainaccount ma
JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
JOIN dbo.generaljournalentry gje ON gje.recid = gjae.generaljournalentry
WHERE ma.mainaccountid IN ('505000','505840') AND gje.accountingdate >= '2026-10-11' AND gje.accountingdate < '2026-10-17'
GROUP BY CAST(gje.accountingdate AS date), ma.mainaccountid COLLATE DATABASE_DEFAULT, gjae.postingtype ORDER BY 1,2,3;
