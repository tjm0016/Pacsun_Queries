/* Which journal produced each 505000 GL line, 8/17-8/19.
   Amount taken straight from the GL (authoritative), attributed via the voucher. */
WITH gl AS (
    SELECT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher,
           CAST(gje.accountingdate AS date) AS acctdate,
           gjae.ledgeraccount COLLATE DATABASE_DEFAULT AS ledgeraccount,
           SUM(gjae.accountingcurrencyamount) AS gl_amt,
           COUNT(*) AS gl_lines
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000'
      AND gje.accountingdate >= '2026-08-17' AND gje.accountingdate < '2026-08-20'
    GROUP BY gje.subledgervoucher, CAST(gje.accountingdate AS date), gjae.ledgeraccount
),
jrnl AS (
    SELECT DISTINCT t.voucher COLLATE DATABASE_DEFAULT AS voucher,
           jt.journalnameid COLLATE DATABASE_DEFAULT AS journalnameid
    FROM dbo.inventjournaltrans t
    JOIN dbo.inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = t.journalid COLLATE DATABASE_DEFAULT
    WHERE t.transdate >= '2026-08-10' AND t.transdate < '2026-08-21'
)
SELECT gl.acctdate,
       gl.ledgeraccount,
       ISNULL(jrnl.journalnameid, '(not an inventory journal)') AS source_journal,
       COUNT(DISTINCT gl.voucher) AS vouchers,
       SUM(gl.gl_lines)           AS gl_lines,
       SUM(gl.gl_amt)             AS net_amt
FROM gl
LEFT JOIN jrnl ON jrnl.voucher = gl.voucher
GROUP BY gl.acctdate, gl.ledgeraccount, ISNULL(jrnl.journalnameid, '(not an inventory journal)')
ORDER BY gl.acctdate, gl.ledgeraccount, 6 DESC;
