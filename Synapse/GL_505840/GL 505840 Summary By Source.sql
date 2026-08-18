/* ============================================================================
   GL 505840 "DC to ERP over/short variances" - what drives the account
   Rolls every 505840 posting up to its source, since go-live.

   Three posting types land here:
     93 InventProfit / 94 InventLoss  -> inventory subledger (has SKU detail)
     14 Ledger journal                -> manual GL entries (no SKU detail)
   ============================================================================ */
WITH v AS (
  SELECT ge.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher,
         MIN(CAST(ge.accountingdate AS date)) AS accountingdate,
         SUM(gae.accountingcurrencyamount)    AS gl_net,
         SUM(ABS(gae.accountingcurrencyamount)) AS gl_gross,
         MAX(CASE WHEN gae.postingtype = 14 THEN 1 ELSE 0 END) AS is_manual_gl
  FROM dbo.generaljournalaccountentry gae
  JOIN dbo.generaljournalentry ge
        ON ge.recid = gae.generaljournalentry AND ge.partition = gae.partition
  JOIN dbo.mainaccount ma
        ON ma.recid = gae.mainaccount AND ma.partition = gae.partition
  WHERE ma.mainaccountid = '505840'
    AND ISNULL(gae.IsDelete,0)=0 AND ISNULL(ge.IsDelete,0)=0
  GROUP BY ge.subledgervoucher COLLATE DATABASE_DEFAULT
),
src AS (   -- attach the inventory journal that owns each voucher (if any)
  SELECT DISTINCT v.voucher, jt.journalnameid COLLATE DATABASE_DEFAULT AS journalnameid
  FROM v
  LEFT JOIN dbo.inventjournaltrans ijt
         ON ijt.voucher COLLATE DATABASE_DEFAULT = v.voucher
        AND ijt.dataareaid = '1001' AND ISNULL(ijt.IsDelete,0)=0
  LEFT JOIN dbo.inventjournaltable jt
         ON jt.journalid COLLATE DATABASE_DEFAULT = ijt.journalid COLLATE DATABASE_DEFAULT
        AND jt.dataareaid = '1001' AND ISNULL(jt.IsDelete,0)=0
)
SELECT FORMAT(v.accountingdate,'yyyy-MM')                                  AS acct_month,
       COALESCE(src.journalnameid,
                CASE WHEN v.is_manual_gl = 1 THEN 'Manual GL journal (no SKU)'
                     ELSE '(unattributed)' END)                            AS source,
       COUNT(DISTINCT v.voucher)                                           AS vouchers,
       SUM(v.gl_net)                                                       AS net_505840,
       SUM(v.gl_gross)                                                     AS gross_505840
FROM v
LEFT JOIN src ON src.voucher = v.voucher
GROUP BY FORMAT(v.accountingdate,'yyyy-MM'),
         COALESCE(src.journalnameid,
                  CASE WHEN v.is_manual_gl = 1 THEN 'Manual GL journal (no SKU)'
                       ELSE '(unattributed)' END)
ORDER BY acct_month, gross_505840 DESC;
