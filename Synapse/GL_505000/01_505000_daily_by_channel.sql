WITH gl AS (
    SELECT CAST(gje.accountingdate AS date) AS acctdate,
           gjae.ledgeraccount AS ledgeraccount,
           gjae.accountingcurrencyamount AS amt,
           gje.subledgervoucher AS voucher
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000'
      AND gje.accountingdate >= '2026-08-17' AND gje.accountingdate < '2026-08-20'
)
SELECT acctdate, ledgeraccount, COUNT(*) AS gl_lines, COUNT(DISTINCT voucher) AS vouchers, SUM(amt) AS net_amt
FROM gl
GROUP BY acctdate, ledgeraccount
HAVING ABS(SUM(amt)) > 0.005
ORDER BY acctdate, ABS(SUM(amt)) DESC;
