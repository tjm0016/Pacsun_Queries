/*
  Returns double-booking / DC-sync write-off trace  (investigation 2026-08-06)

  QUESTION (from controller): why did the first COU-DCSYNC posted after the July sync pause
  write off large amounts on top ecom styles (e.g. 0860-45421-0365 -1,239u / $20.2K)?
  Hypotheses tested: (1) double PO receipts, (2) missing PIX / non-4901/4905 leakage,
  (3) returns never received. ALL THREE REFUTED.

  ROOT CAUSE FOUND: every ecom customer return into 4905 (Digital DC) is booked in D365
  THREE times for ONE physical unit:
    +1 Active     rc=0  return sales-order receipt (the correct ERP booking)
    +1 Lock_Code  PIX 604/02 "Returns Acknowledgement SKU Detail"  -> MOV-DCADJ add
    +1 Lock_Code  PIX 606/04 "Returns: Unallocatable Inventory"    -> MOV-DCADJ add
  604/02 and 606/04 are the SAME return event (same pacwmpxcasn RMA, consecutive pxtran)
  and BOTH are rows in pacwmpixtransactionmappingtable -> both post.
  => +2 phantom units per returned unit. The nightly 605 daily sync silently removes the
  phantoms (part of the "normal" small daily 4905 negative). When journal creation paused
  7/14-7/28, ~12 business days of phantoms accumulated and the first catch-up journal
  (INV-01348397, created 7/29, posted 7/30) removed them all at once = the "write-off".

  Tie-out for the pause window 7/13->7/29 (per style):
    style             604/02  606/04  phantom(2x)   catch-up sync 7/29..8/2
    0860-44538-0075   +731    +731    +1,462        -1,716
    0860-45421-0365   +729    +729    +1,458        -2,028   (rest = in-flight outbound drift)
    0860-45421-0024   +341    +341      +682          -857
  Split of the write-off ~50/50 Active vs Lock_Code — consistent with one phantom stranded
  in Lock_Code and one surfacing in Active after the unlock pair moves the unit.

  BONUS: the "duplicate 20 EA voucher rows" seen in the Inventory Value Report
  (INV-01111952 7/14, INV-01122312 7/15) are the same double-mapping disease on the
  lock/unlock flow: 300/01/19+606/02/19 (lock, -20 each) and 300/01/20+606/02/20
  (unlock, +20 each) carry the SAME pxtran — one physical event posted twice.
  When both legs double, it washes; when only one leg posts (7/15) it strands +40.

  OVER/SHORT NOTE (verified): the ISS-00860 logic IS live — 606/02 lines whose ref 25 carries an
  isOverShort lock code (LC/LW/MS only, per pacwmlockcodereference) post SIGN-INVERTED vs PXINAT
  (A into LC -> negative write-off). "Ignore" applies only to 608-12 moves between two over/short
  locations. The returns pair rides ref25=PP (Pending Putaway, overshort=0) — unaffected.
  Second defect: the 3xx twin (300/01/19-20, same pxtran, BLANK ref 25) posts plainly, so on
  over/short lock events the twins land SAME-signed (-20 + -20) = double the intended write-off,
  instead of cancelling.

  FIX CANDIDATES: returns — remove 604/02 (or 606/04) from pacwmpixtransactionmappingtable so a
  return books once. Over/short lock events — suppress the 3xx twin (it can't see the lock code)
  and keep the inverted 6xx leg. Do NOT blanket-dedupe 3xx/6xx by pxtran.

  Synapse serverless, DB dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc, dataareaid 1001.
*/

DECLARE @items TABLE (itemid NVARCHAR(20));
INSERT @items VALUES ('0860-45421-0365'),('0860-44538-0075'),('0860-45421-0024');
DECLARE @pause_from DATE = '2026-07-13', @pause_to DATE = '2026-07-29';

-- (1) COU-DCSYNC journals per item/warehouse around the pause: the catch-up is obvious
SELECT jt.journalid,
       CONVERT(date, jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS created_pst,
       CONVERT(date, jt.posteddatetime) AS posted,
       jl.itemid, dj.inventlocationid AS wh,
       COUNT(*) AS lines, SUM(jl.qty) AS net_qty, SUM(jl.counted) AS wm_counted, SUM(jl.costamount) AS cost
FROM inventjournaltable jt
JOIN inventjournaltrans jl ON jl.journalid=jt.journalid AND jl.dataareaid=jt.dataareaid
JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
WHERE jt.dataareaid='1001' AND jt.journalnameid='COU-DCSYNC'
  AND jl.itemid IN (SELECT itemid FROM @items)
  AND jt.createddatetime >= '2026-07-01'
GROUP BY jt.journalid, CONVERT(date, jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time'),
         CONVERT(date, jt.posteddatetime), jl.itemid, dj.inventlocationid
ORDER BY jl.itemid, created_pst, wh;

-- (2) What inflated D365 at 4905 during the pause: daily net by referencecategory
--     (rc=4 MOV-DCADJ positive every day with no rc=13 true-up = the accumulating phantom)
SELECT t.itemid, CONVERT(date,t.datephysical) AS d,
       SUM(CASE WHEN o.referencecategory=0  THEN t.qty ELSE 0 END) AS sales_net,
       SUM(CASE WHEN o.referencecategory=3  THEN t.qty ELSE 0 END) AS po_rcpt,
       SUM(CASE WHEN o.referencecategory=4  THEN t.qty ELSE 0 END) AS mov_net,
       SUM(CASE WHEN o.referencecategory=6  THEN t.qty ELSE 0 END) AS ctn_net,
       SUM(CASE WHEN o.referencecategory=13 THEN t.qty ELSE 0 END) AS sync_net,
       SUM(t.qty) AS day_net
FROM inventtrans t
JOIN inventdim d ON d.inventdimid=t.inventdimid AND d.dataareaid=t.dataareaid
LEFT JOIN inventtransorigin o ON o.recid=t.inventtransorigin AND o.dataareaid=t.dataareaid
WHERE t.itemid IN (SELECT itemid FROM @items) AND t.dataareaid='1001' AND d.inventlocationid='4905'
  AND t.datephysical >= '2026-07-12' AND t.datephysical < '2026-08-01'
GROUP BY t.itemid, CONVERT(date,t.datephysical)
ORDER BY t.itemid, d;

-- (3) PIX type/code decomposition of the pause-window MOV-DCADJ churn at 4905.
--     604/02 and 606/04 come out IDENTICAL (paired adds) = the return double-book.
SELECT jl.itemid, jl.pacwmpxtxtp AS txtp, jl.pacwmpxtxcd AS txcd, jl.pacwmpxaccd AS accd,
       COUNT(*) AS lines,
       SUM(CASE WHEN jl.qty>0 THEN jl.qty ELSE 0 END) AS adds,
       SUM(CASE WHEN jl.qty<0 THEN jl.qty ELSE 0 END) AS subs,
       SUM(jl.qty) AS net
FROM inventjournaltable jt
JOIN inventjournaltrans jl ON jl.journalid=jt.journalid AND jl.dataareaid=jt.dataareaid
JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
WHERE jt.dataareaid='1001' AND jl.itemid IN (SELECT itemid FROM @items)
  AND dj.inventlocationid='4905' AND jt.journalnameid='MOV-DCADJ'
  AND jl.transdate >= @pause_from AND jl.transdate < @pause_to
GROUP BY jl.itemid, jl.pacwmpxtxtp, jl.pacwmpxtxcd, jl.pacwmpxaccd
ORDER BY jl.itemid, net DESC;

-- (4) Proof of the pairing: same RMA (pacwmpxcasn) posts under BOTH 604/02 and 606/04
--     with consecutive pxtran numbers. Change the item/date to spot-check others.
SELECT jl.journalid, jl.transdate, dj.inventsizeid AS size, dj.wmslocationid AS bucket,
       jl.qty, jl.pacwmpxtxtp, jl.pacwmpxtxcd, jl.pacwmpxtran, jl.pacwmpxcasn
FROM inventjournaltrans jl
JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
WHERE jl.dataareaid='1001' AND jl.itemid='0860-44538-0075'
  AND jl.transdate='2026-07-21' AND dj.inventlocationid='4905'
  AND jl.pacwmpxtxtp IN ('604','606') AND jl.pacwmpxtxcd IN ('02','04')
ORDER BY jl.pacwmpxcasn, jl.pacwmpxtxtp;

-- (5) The third booking: return sales-order receipts (rc=0, qty>0) into 4905 Active
SELECT t.itemid, d.wmslocationid AS bucket, COUNT(*) AS lines, SUM(t.qty) AS units
FROM inventtrans t
JOIN inventdim d ON d.inventdimid=t.inventdimid AND d.dataareaid=t.dataareaid
JOIN inventtransorigin o ON o.recid=t.inventtransorigin AND o.dataareaid=t.dataareaid
WHERE t.itemid IN (SELECT itemid FROM @items) AND t.dataareaid='1001' AND d.inventlocationid='4905'
  AND o.referencecategory=0 AND t.qty>0
  AND t.datephysical >= @pause_from AND t.datephysical < @pause_to
GROUP BY t.itemid, d.wmslocationid
ORDER BY t.itemid;

-- (6) Mapping-table rows behind the double-post (the fix target)
SELECT pxtxtp, pxtxcd, pxaccd, journalnameid, reasoncode
FROM pacwmpixtransactionmappingtable
WHERE (pxtxtp='604') OR (pxtxtp='606' AND pxtxcd IN ('02','04'))
   OR (pxtxtp='300' AND pxtxcd IN ('01','04'))
ORDER BY pxtxtp, pxtxcd, pxaccd;

-- (7) TRUE double-PO-receipt test (hypothesis 1, refuted): same PO+size+packingslip 2x.
--     Grouping by PO+size+DATE gives false positives (multi-carton receiving);
--     the packing slip is the dedupe key. Only 1 real dup (16u) in these styles' history.
SELECT t.itemid, o.referenceid AS po, d.inventsizeid AS size, t.packingslipid, t.voucherphysical,
       COUNT(*) AS lines, SUM(t.qty) AS units
FROM inventtrans t
JOIN inventdim d ON d.inventdimid=t.inventdimid AND d.dataareaid=t.dataareaid
JOIN inventtransorigin o ON o.recid=t.inventtransorigin AND o.dataareaid=t.dataareaid
WHERE t.itemid IN (SELECT itemid FROM @items) AND t.dataareaid='1001'
  AND o.referencecategory=3 AND t.qty>0
GROUP BY t.itemid, o.referenceid, d.inventsizeid, t.packingslipid, t.voucherphysical
HAVING COUNT(*) > 1
ORDER BY units DESC;
