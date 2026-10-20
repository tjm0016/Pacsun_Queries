-- Tests the theory that pre-10/1 NFC was inflated by failed auths: rebuilds BI's NFC % of store sales from
-- D365 RetailTransactionPaymentTrans (Success-only payments before 10/1). Result 2026-10-20: 65-71% every week
-- 8/29-10/17, no step at 10/1; multi-card and mixed-entry transaction shares flat (2.4% / 0.3%).
-- BI-style NFC % rebuilt from D365 POS payment rows (store transactions), by fiscal week ending Saturday
WITH p AS (
  SELECT t.transactionid, t.store, t.terminal, CAST(t.transdate AS date) d,
         t.amounttendered, t.pacentrytypeid, t.tendertype
  FROM retailtransactionpaymenttrans t
  WHERE t.transdate >= '2026-08-23' AND t.transdate < '2026-10-18' AND ISNULL(t.voidstatus,0) = 0
    AND t.store < '4000'),
tx AS (
  SELECT transactionid, store, terminal, MIN(d) d, SUM(amounttendered) tender_amt,
         MAX(CASE WHEN pacentrytypeid = 'Contactless' THEN 1 ELSE 0 END) nfc,
         SUM(CASE WHEN tendertype IN ('69','70','71','72','73','75') THEN 1 ELSE 0 END) card_rows,
         COUNT(DISTINCT CASE WHEN tendertype IN ('69','70','71','72','73') THEN pacentrytypeid END) card_entry_types
  FROM p GROUP BY transactionid, store, terminal)
SELECT DATEADD(day, 7 - DATEPART(weekday, d), d) week_ending,
  COUNT(*) txns,
  CAST(SUM(CASE WHEN tender_amt > 0 THEN tender_amt END) AS bigint) sale_tender_amt,
  CAST(100.0 * SUM(CASE WHEN tender_amt > 0 AND nfc = 1 THEN tender_amt END) / SUM(CASE WHEN tender_amt > 0 THEN tender_amt END) AS decimal(5,1)) nfc_pct_of_sales,
  CAST(100.0 * SUM(nfc) / COUNT(*) AS decimal(5,1)) nfc_pct_of_txns,
  CAST(100.0 * SUM(CASE WHEN card_rows > 1 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2)) pct_txns_multi_card,
  CAST(100.0 * SUM(CASE WHEN card_entry_types > 1 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,2)) pct_txns_mixed_entry
FROM tx GROUP BY DATEADD(day, 7 - DATEPART(weekday, d), d) ORDER BY 1
