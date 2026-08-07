/*
  Monthly impact of the WM PIX double-booking defects  (measured 2026-08-07 for July 2026)

  Companion to returns_double_booking_writeoff_trace.sql (which proves the mechanism on 3 styles).
  This quantifies it chain-wide, all items, both DCs, for a full month.

  ============ JULY 2026 RESULTS ============

  (V) RETURNS PAIR 604/02 + 606/04 -- MOV-DCADJ, all items:
      604/02 : 72,347 lines | 71,386 distinct RMAs | 72,397 units | $909,654.34   ALL at 4905
      606/04 : 72,347 lines | 71,386 distinct RMAs | 72,397 units | $909,654.48   ALL at 4905
      -> IDENTICAL on every measure = the two messages pair 1:1 chain-wide (not just on sample styles).
      -> 144,794 units / $1,819,309 booked as adds for what the legit rc=0 return receipts
         recorded as 67,592 units at 4905 in the same month.
      -> JUNE 2026 for comparison: 70,078 units / $859,573 each leg -> steady ongoing run rate,
         NOT a July anomaly. ~70-72K units/leg/month, ~$0.9M/leg/month.

  (W2) 3xx/6xx TWINS sharing pacwmpxtran (same WM event described twice):
      OFFSETTING (nets 0)   : 305,703 trans | 6,152,368 units gross | $73.7M gross  <- washes; pure GL churn
      SAME-SIGNED (doubled) :   3,637 trans |    36,932 units       |   $460,085    <- REAL over-write-off
        by warehouse: 4905 = 978 trans / 24,041 u / $325,588
                      4901 = 2,659 trans / 12,891 u / $134,497
      Same-signed happens when over/short (LC/LW/MS) flips the 6xx leg's sign while the 3xx twin
      (blank ref 25) posts plainly -> both land the same direction = 2x the intended write-off.

  (X) CONTEXT -- posted COU-DCSYNC July 2026 (what the sync actually adjusted):
      4905 : 96,899 lines | -173,902 units | -$2,101,990
      4901 : 28,652 lines |  +86,609 units | +$1,125,459

  ============ CONCLUSION ============
  Phantom units at 4905 the sync had to remove in July:
    conservative (1 redundant returns leg):  72,397 + 24,041 =  96,438 u / $1,235,242 = 55% of units, 59% of $
    if BOTH PIX return legs are redundant : 144,794 + 24,041 = 168,835 u / $2,144,897 = 97% of units, ~100% of $
  i.e. essentially the ENTIRE monthly 4905 sync write-off is these two defects.

  NOTE ON MATERIALITY: this is not $1-2M of lost value. Phantom units are created by MOV-DCADJ and
  removed by the sync, so the two largely offset in the GL. The real costs are (a) gross churn through
  the inventory-adjustment accounts, (b) inventory overstatement in the window between creation and
  the sync removal (1 day normally, ~2 weeks during the 7/14-7/28 outage), and (c) the resulting
  catch-up journal reading as a large shrink event to finance.
*/

DECLARE @from DATE = '2026-07-01', @to DATE = '2026-08-01';

-- (V) Returns pair volume + value, by warehouse. The two legs should come back IDENTICAL.
SELECT dj.inventlocationid AS wh, jl.pacwmpxtxtp AS txtp, jl.pacwmpxtxcd AS txcd,
       COUNT(*) AS lines, COUNT(DISTINCT jl.pacwmpxcasn) AS distinct_rmas,
       SUM(jl.qty) AS units, SUM(jl.costamount) AS cost
FROM inventjournaltable jt
JOIN inventjournaltrans jl ON jl.journalid=jt.journalid AND jl.dataareaid=jt.dataareaid
JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
WHERE jt.dataareaid='1001' AND jt.journalnameid='MOV-DCADJ'
  AND jl.transdate >= @from AND jl.transdate < @to
  AND ((jl.pacwmpxtxtp='604' AND jl.pacwmpxtxcd='02') OR (jl.pacwmpxtxtp='606' AND jl.pacwmpxtxcd='04'))
GROUP BY dj.inventlocationid, jl.pacwmpxtxtp, jl.pacwmpxtxcd
ORDER BY wh, txtp;

-- (W2) 3xx/6xx twins classified: offsetting (harmless wash) vs same-signed (doubled write-off).
--      NOTE: 'tran' is a T-SQL reserved word -- alias the column as trn.
WITH ln AS (
  SELECT jl.pacwmpxtran AS trn, dj.inventlocationid AS wh,
         CASE WHEN jl.pacwmpxtxtp LIKE '3%' THEN 1 ELSE 0 END AS is3,
         CASE WHEN jl.pacwmpxtxtp LIKE '6%' THEN 1 ELSE 0 END AS is6,
         jl.qty, jl.costamount
  FROM inventjournaltable jt
  JOIN inventjournaltrans jl ON jl.journalid=jt.journalid AND jl.dataareaid=jt.dataareaid
  JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
  WHERE jt.dataareaid='1001' AND jt.journalnameid='MOV-DCADJ'
    AND jl.transdate >= @from AND jl.transdate < @to
    AND jl.pacwmpxtran IS NOT NULL AND jl.pacwmpxtran <> ''
), agg AS (
  SELECT trn, MIN(wh) AS wh,
         SUM(CASE WHEN is3=1 THEN qty ELSE 0 END) AS q3,
         SUM(CASE WHEN is6=1 THEN qty ELSE 0 END) AS q6,
         SUM(CASE WHEN is3=1 THEN costamount ELSE 0 END) AS c3
  FROM ln GROUP BY trn HAVING MAX(is3)=1 AND MAX(is6)=1
)
SELECT CASE WHEN SIGN(q3)=SIGN(q6) AND q3<>0 THEN 'SAME-SIGNED (doubled)'
            WHEN q3 = -q6 AND q3<>0 THEN 'OFFSETTING (nets 0)'
            ELSE 'other' END AS pattern,
       wh, COUNT(*) AS trans, SUM(ABS(q3)) AS redundant_units, SUM(ABS(c3)) AS redundant_cost
FROM agg
GROUP BY CASE WHEN SIGN(q3)=SIGN(q6) AND q3<>0 THEN 'SAME-SIGNED (doubled)'
              WHEN q3 = -q6 AND q3<>0 THEN 'OFFSETTING (nets 0)'
              ELSE 'other' END, wh
ORDER BY pattern, redundant_units DESC;

-- (X) Denominator: what the posted daily sync actually adjusted that month.
SELECT dj.inventlocationid AS wh, COUNT(*) AS lines, SUM(jl.qty) AS net_units, SUM(jl.costamount) AS net_cost
FROM inventjournaltable jt
JOIN inventjournaltrans jl ON jl.journalid=jt.journalid AND jl.dataareaid=jt.dataareaid
JOIN inventdim dj ON dj.inventdimid=jl.inventdimid AND dj.dataareaid=jl.dataareaid
WHERE jt.dataareaid='1001' AND jt.journalnameid='COU-DCSYNC' AND jt.posted=1
  AND jl.transdate >= @from AND jl.transdate < @to
GROUP BY dj.inventlocationid ORDER BY net_cost;

/*  ============ OVERSELL / CUSTOMER-IMPACT CHECK (2026-08-07) ============
    Question: during 7/14-7/28, D365 Active ran 8-10x WM's count on high-return styles.
    Did that overstatement cause oversells, short-ships, or cancellations?  ANSWER: no evidence.

    (O1) 4905 July salesline: 882,868 lines | 755,075 qty | remainsalesphysical = 0 |
         lines with remaining = 0  -> every ecom line fully shipped, nothing stranded.
    (O2) ALL 4905 salesline are salesstatus=3 (Invoiced). Chain-wide July: only 16,147 status-1
         vs 4,112,502 status-3. D365 receives ecom sales POST-fulfillment and never holds an open
         ecom order => D365 is a downstream book of record, NOT the availability/promise engine.
    (O3) Shipping volume ROSE through the outage: 7/14 43,227u, 7/22 36,362u,
         7/27 52,958u (month's biggest day), 7/28 41,941u. No fulfillment collapse.
         (Tiny days 7/5, 7/12, 7/19, 8/2 = Sunday posting cadence, not outages.)
    (O4) No shortage signal: 618/55 verification variance flat 840-2,150/day before/during/after;
         ZERO 618/45 (Picking De-Allocation/Shortage) and zero shortage action codes in Jun-Jul.

    CAVEAT: O1 is partly structural -- if lines arrive already invoiced, remainsalesphysical is 0
    by construction, so a failed order would never appear in D365 at all. Definitively ruling out
    oversell requires the ecom/OMS (SFCC/MAO) availability feed source, which is NOT in D365
    Synapse. Logic favors no exposure (WM held the correct count throughout and does the picking),
    but confirm which system feeds ecom ATP before declaring this closed.
*/

-- (O1) Any ecom line left unshipped at 4905?
SELECT COUNT(*) AS lines, SUM(sl.qtyordered) AS qty_ordered,
       SUM(sl.remainsalesphysical) AS remain_unshipped,
       SUM(CASE WHEN sl.remainsalesphysical<>0 THEN 1 ELSE 0 END) AS lines_with_remaining
FROM salesline sl
JOIN inventdim d ON d.inventdimid=sl.inventdimid AND d.dataareaid=sl.dataareaid
WHERE sl.dataareaid='1001' AND d.inventlocationid='4905'
  AND sl.createddatetime >= @from AND sl.createddatetime < @to;

-- (O3) Daily shipped units at 4905 -- look for a collapse during the outage window (there isn't one).
SELECT CONVERT(date, t.datephysical) AS d, COUNT(*) AS lines,
       SUM(CASE WHEN t.qty<0 THEN -t.qty ELSE 0 END) AS units_shipped
FROM inventtrans t
JOIN inventdim d ON d.inventdimid=t.inventdimid AND d.dataareaid=t.dataareaid
JOIN inventtransorigin o ON o.recid=t.inventtransorigin AND o.dataareaid=t.dataareaid
WHERE t.dataareaid='1001' AND d.inventlocationid='4905' AND o.referencecategory=0
  AND t.datephysical >= @from AND t.datephysical < @to
GROUP BY CONVERT(date, t.datephysical) ORDER BY d;

-- (Z) The one legitimate return booking, for comparison against the 604/606 unit counts.
SELECT COUNT(*) AS lines, SUM(t.qty) AS return_units
FROM inventtrans t
JOIN inventdim d ON d.inventdimid=t.inventdimid AND d.dataareaid=t.dataareaid
JOIN inventtransorigin o ON o.recid=t.inventtransorigin AND o.dataareaid=t.dataareaid
WHERE t.dataareaid='1001' AND d.inventlocationid='4905'
  AND o.referencecategory=0 AND t.qty>0
  AND t.datephysical >= @from AND t.datephysical < @to;
