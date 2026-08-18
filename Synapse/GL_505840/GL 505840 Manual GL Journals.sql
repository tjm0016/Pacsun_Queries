/* The 311 vouchers that hit 505840 with postingtype 14 (manual Ledger journal)
   -- these have NO inventory subledger detail (no item / qty). */
SELECT CAST(ge.accountingdate AS date) AS AccountingDate,
       ge.subledgervoucher             AS Voucher,
       ge.journalnumber                AS GLJournalNumber,
       ge.documentnumber               AS DocumentNumber,
       ge.ledgerpostingjournal         AS LedgerJournalId,
       gae.ledgeraccount               AS LedgerAccount,
       gae.text                        AS Description,
       gae.quantity                    AS Qty,
       gae.accountingcurrencyamount    AS GL505840_Amount,
       gae.createdby                   AS CreatedBy,
       CAST(gae.createddatetime AS date) AS CreatedDate
FROM dbo.generaljournalaccountentry gae
JOIN dbo.generaljournalentry ge
      ON ge.recid = gae.generaljournalentry AND ge.partition = gae.partition
JOIN dbo.mainaccount ma
      ON ma.recid = gae.mainaccount AND ma.partition = gae.partition
WHERE ma.mainaccountid = '505840'
  AND gae.postingtype = 14
  AND ISNULL(gae.IsDelete,0)=0 AND ISNULL(ge.IsDelete,0)=0
ORDER BY ge.accountingdate, ge.subledgervoucher;
