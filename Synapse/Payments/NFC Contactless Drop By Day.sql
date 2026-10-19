-- NFC / Contactless drop: D365 POS payment rows still carry the entry type, but the ledger lines BI reads lost it on 10/1.
-- One row per ledger trans date. Run on D365 prod Synapse (serverless).
WITH card AS (            -- card / gift-card tender lines on customer payment journals
  SELECT l.journalnum, CAST(l.transdate AS date) d, l.paymentnotes
  FROM ledgerjournaltrans l
  WHERE l.transdate >= '2026-09-20' AND l.transdate < '2026-10-19'
    AND l.paymmode IN ('69','70','71','72','73','75') AND l.accounttype = 6),
inv AS (                  -- the customer line in the same journal carries the invoice
  SELECT journalnum, MIN(markedinvoice) markedinvoice
  FROM ledgerjournaltrans
  WHERE transdate >= '2026-09-20' AND transdate < '2026-10-19' AND accounttype = 1 AND markedinvoice <> ''
  GROUP BY journalnum),
cls AS (                  -- POS statement vs DC-fulfilled ecom invoice
  SELECT c.d, c.paymentnotes,
         CASE WHEN x.custinvoiceid IS NOT NULL THEN 'ECOM' ELSE 'POS' END src
  FROM card c
  JOIN inv i ON i.journalnum = c.journalnum
  LEFT JOIN pacintecominvoicexref x ON x.custinvoiceid = i.markedinvoice),
ljt AS (
  SELECT d,
    SUM(CASE WHEN src = 'POS' THEN 1 ELSE 0 END) pos_card_lines,
    SUM(CASE WHEN src = 'POS' AND paymentnotes = 'Contactless' THEN 1 ELSE 0 END) pos_ljt_contactless,
    CAST(100.0 * SUM(CASE WHEN src = 'POS' AND paymentnotes IS NOT NULL THEN 1 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN src = 'POS' THEN 1 ELSE 0 END), 0) AS decimal(5,1)) pos_pct_noted,
    SUM(CASE WHEN src = 'ECOM' THEN 1 ELSE 0 END) ecom_card_lines,
    CAST(100.0 * SUM(CASE WHEN src = 'ECOM' AND paymentnotes IS NOT NULL THEN 1 ELSE 0 END)
         / NULLIF(SUM(CASE WHEN src = 'ECOM' THEN 1 ELSE 0 END), 0) AS decimal(5,1)) ecom_pct_noted
  FROM cls GROUP BY d),
rtpt AS (                 -- what MAO sent: entry type on the POS payment rows
  SELECT CAST(transdate AS date) d,
    SUM(CASE WHEN pacentrytypeid = 'Contactless' THEN 1 ELSE 0 END) rtpt_contactless
  FROM retailtransactionpaymenttrans
  WHERE transdate >= '2026-09-20' AND transdate < '2026-10-19'
    AND tendertype IN ('69','70','71','72','73','75') AND ISNULL(voidstatus, 0) = 0
  GROUP BY CAST(transdate AS date))
SELECT l.d trans_date, r.rtpt_contactless, l.pos_ljt_contactless, l.pos_card_lines, l.pos_pct_noted,
       l.ecom_card_lines, l.ecom_pct_noted
FROM ljt l LEFT JOIN rtpt r ON r.d = l.d
ORDER BY l.d;
