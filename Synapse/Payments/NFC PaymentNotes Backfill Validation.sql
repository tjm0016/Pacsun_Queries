-- NFC PaymentNotes Backfill Validation (Synapse, D365 prod)
-- Since 2026-10-01 (PR 1665 / ISS-01666) POS-statement card payment lines in LedgerJournalTrans post with
-- PaymentNotes = NULL, which zeroes the BI/Robling NFC flag. The entry type is still on
-- RetailTransactionPaymentTrans.pacEntryTypeId. This proposes the backfill value per ledger line:
--   card line (accounttype 6) -> customer line in same journal (MarkedInvoice) -> CustInvoiceJour.SalesId
--   -> RetailTransactionTable.SalesOrderId -> RetailTransactionPaymentTrans (same tender, not voided)
--   'unique' = one distinct entry type; 'unique by amount' = resolved by AmountTendered = line amount.
-- DC ecom invoices (pacintecominvoicexref) are excluded; their notes come from a different path and are unaffected.
-- Validated 2026-10-19: replay on 9/27-9/30 reproduced 72,459/72,459 'unique' lines exactly.
-- Change the two dates to move the window.
  SELECT l.recid, l.journalnum, l.transdate, l.paymmode, l.paymentnotes, l.amountcurdebit - l.amountcurcredit amt
  FROM ledgerjournaltrans l
  WHERE l.transdate >= '2026-10-01' AND l.transdate < '2026-10-19' AND l.paymmode IN ('69','70','71','72','73','75') AND l.accounttype = 6),
inv AS (
  SELECT journalnum, MIN(markedinvoice) markedinvoice FROM ledgerjournaltrans
  WHERE transdate >= '2026-10-01' AND transdate < '2026-10-19' AND accounttype = 1 AND markedinvoice <> '' GROUP BY journalnum),
pos AS (
  SELECT c.*, cij.salesid FROM card c JOIN inv i ON i.journalnum = c.journalnum
  JOIN custinvoicejour cij ON cij.invoiceid = i.markedinvoice
  WHERE NOT EXISTS (SELECT 1 FROM pacintecominvoicexref x WHERE x.custinvoiceid = i.markedinvoice)),
cand AS (
  SELECT p.recid, p.amt, r.transactionid, t.pacentrytypeid, t.amounttendered
  FROM pos p JOIN retailtransactiontable r ON r.salesorderid = p.salesid
  JOIN retailtransactionpaymenttrans t ON t.transactionid = r.transactionid AND t.store = r.store AND t.terminal = r.terminal
       AND t.tendertype = p.paymmode AND ISNULL(t.voidstatus,0) = 0),
agg AS (
  SELECT recid, COUNT(DISTINCT transactionid) ntrans, COUNT(*) ncand,
    COUNT(DISTINCT ISNULL(pacentrytypeid,'~')) nent, MIN(ISNULL(pacentrytypeid,'~')) anyent,
    COUNT(DISTINCT CASE WHEN amounttendered = amt THEN ISNULL(pacentrytypeid,'~') END) nent_amt,
    MIN(CASE WHEN amounttendered = amt THEN ISNULL(pacentrytypeid,'~') END) ent_amt
  FROM cand GROUP BY recid),
res AS (
  SELECT p.transdate, p.paymentnotes, a.ntrans, a.ncand,
    CASE WHEN a.recid IS NULL THEN NULL WHEN a.nent = 1 THEN a.anyent WHEN a.nent_amt = 1 THEN a.ent_amt END proposed,
    CASE WHEN a.recid IS NULL THEN 'no RTPT match' WHEN a.nent = 1 THEN 'unique' WHEN a.nent_amt = 1 THEN 'unique by amount' ELSE 'ambiguous' END how
  FROM pos p LEFT JOIN agg a ON a.recid = p.recid)
SELECT how, COUNT(*) n, SUM(CASE WHEN paymentnotes IS NULL THEN 1 ELSE 0 END) currently_null,
  SUM(CASE WHEN paymentnotes IS NULL AND proposed IS NOT NULL AND proposed <> '~' THEN 1 ELSE 0 END) would_fill,
  SUM(CASE WHEN paymentnotes IS NULL AND proposed = 'Contactless' THEN 1 ELSE 0 END) fill_contactless,
  SUM(CASE WHEN paymentnotes IS NULL AND proposed = 'Chip Read' THEN 1 ELSE 0 END) fill_chip,
  SUM(CASE WHEN paymentnotes IS NULL AND proposed = 'ApplePay' THEN 1 ELSE 0 END) fill_applepay,
  SUM(CASE WHEN paymentnotes IS NOT NULL AND proposed IS NOT NULL AND proposed <> paymentnotes THEN 1 ELSE 0 END) conflicts,
  MIN(transdate) mind, MAX(transdate) maxd
FROM res GROUP BY how ORDER BY 1
