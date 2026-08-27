/* A: does inventjournaltrans.costamount reconcile to the GL for these MOV-DCADJ vouchers? */
WITH gl AS (
    SELECT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher,
           CAST(gje.accountingdate AS date) AS acctdate,
           SUM(gjae.accountingcurrencyamount) AS gl_amt
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000'
      AND gje.accountingdate = '2026-08-18'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
    GROUP BY gje.subledgervoucher, CAST(gje.accountingdate AS date)
)
SELECT 'GL total'                AS metric, COUNT(*) AS vouchers, SUM(gl.gl_amt) AS amt FROM gl
UNION ALL
SELECT 'journal costamount (-)', COUNT(DISTINCT t.voucher), SUM(-t.costamount)
FROM gl JOIN dbo.inventjournaltrans t ON t.voucher COLLATE DATABASE_DEFAULT = gl.voucher;

/* B: PIX identity breakdown of every journal line in those vouchers */
WITH gl AS (
    SELECT DISTINCT gje.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher
    FROM dbo.mainaccount ma
    JOIN dbo.generaljournalaccountentry gjae ON gjae.mainaccount = ma.recid
    JOIN dbo.generaljournalentry gje         ON gje.recid = gjae.generaljournalentry
    WHERE ma.mainaccountid = '505000'
      AND gje.accountingdate = '2026-08-18'
      AND gjae.ledgeraccount COLLATE DATABASE_DEFAULT IN ('505000-14901-59000','505000-74905-70400')
)
SELECT dim.inventlocationid                        AS warehouse,
       ISNULL(NULLIF(t.pacwmpxtxtp,''),'(none)')   AS pxtxtp,
       ISNULL(NULLIF(t.pacwmpxtxcd,''),'(none)')   AS pxtxcd,
       ISNULL(NULLIF(t.pacwmpxaccd,''),'(none)')   AS pxaccd,
       ISNULL(NULLIF(t.pacwmpxrscd,''),'(blank)')  AS pxrscd,
       COUNT(*)                                    AS lines,
       SUM(t.qty)                                  AS qty,
       SUM(-t.costamount)                          AS gl505000_amt
FROM gl
JOIN dbo.inventjournaltrans t ON t.voucher COLLATE DATABASE_DEFAULT = gl.voucher
LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = t.inventdimid COLLATE DATABASE_DEFAULT
GROUP BY dim.inventlocationid,
         ISNULL(NULLIF(t.pacwmpxtxtp,''),'(none)'),
         ISNULL(NULLIF(t.pacwmpxtxcd,''),'(none)'),
         ISNULL(NULLIF(t.pacwmpxaccd,''),'(none)'),
         ISNULL(NULLIF(t.pacwmpxrscd,''),'(blank)')
ORDER BY 1, 8;
