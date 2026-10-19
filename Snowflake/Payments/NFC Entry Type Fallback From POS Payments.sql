-- NFC Entry Type Fallback From POS Payments (Robling Snowflake, DW_LND)
-- Since 2026-10-01 D365 posts POS-statement card lines with LEDGERJOURNALTRANS.PAYMENTNOTES = NULL
-- (PR 1665 defect), which zeroes NFC_FLG. The entry type still exists on D365
-- RetailTransactionPaymentTrans.pacEntryTypeId, but Robling's LP_RETAILTRANSACTIONPAYMENTTRANS extract
-- does NOT include that column. Prerequisite: Robling adds PACENTRYTYPEID to that extract and reloads
-- at least 2026-10-01 forward.
-- Join path verified 2026-10-19: 498,460 / 498,460 POS card lines (10/1-10/18) link to an RTPT row.
-- Same logic replayed in Synapse on 9/27-9/30 reproduced D365's own PAYMENTNOTES on 72,459 / 72,459 lines.
-- Effective note = COALESCE(LJT.PAYMENTNOTES, resolved RTPT entry type). Only use the RTPT value when the
-- transaction has exactly one distinct entry type for that tender (covers 99.6%); otherwise leave NULL.
with card as (
  select l.recid, l.journalnum, l.transdate, l.paymmode, l.paymentnotes
  from DW_LND.LP_LEDGERJOURNALTRANS l
  where l.transdate >= '2026-10-01' and l.paymmode in ('69','70','71','72','73','75')
    and l.accounttype = 6 and l.isdelete is null),
inv as (
  select journalnum, min(markedinvoice) markedinvoice
  from DW_LND.LP_LEDGERJOURNALTRANS
  where transdate >= '2026-10-01' and accounttype = 1 and markedinvoice <> '' and isdelete is null
  group by journalnum),
pos as (
  select c.*, cij.salesid
  from card c
  join inv i on i.journalnum = c.journalnum
  join DW_LND.LP_CUSTINVOICEJOUR cij on cij.invoiceid = i.markedinvoice and cij.isdelete is null
  where not exists (select 1 from DW_LND.LP_PACINTECOMINVOICEXREF x
                    where x.custinvoiceid = i.markedinvoice and x.isdelete is null)),
ent as (
  select p.recid,
         iff(count(distinct coalesce(t.pacentrytypeid,'~')) = 1, max(t.pacentrytypeid), null) rtpt_entry
  from pos p
  join DW_LND.LP_RETAILTRANSACTIONTABLE r on r.salesorderid = p.salesid and r.isdelete is null
  join DW_LND.LP_RETAILTRANSACTIONPAYMENTTRANS t
    on t.transactionid = r.transactionid and t.store = r.store and t.terminal = r.terminal
   and t.tendertype = p.paymmode and coalesce(t.voidstatus,0) = 0 and t.isdelete is null
  group by p.recid)
select p.recid ledgerjournaltrans_recid, p.transdate, p.paymentnotes original_note,
       coalesce(p.paymentnotes, e.rtpt_entry) effective_note,
       iff(coalesce(p.paymentnotes, e.rtpt_entry) = 'Contactless', 'Y', 'N') nfc_flg
from pos p left join ent e on e.recid = p.recid;
