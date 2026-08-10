/*==============================================================================
  PIX DOUBLE-BOOK DETECTOR  ("Two-Arm Duplicate-Effect Ledger")
  Target : D365 F&O Synapse serverless  (dataverse_psprod_*)   READ-ONLY
  Author : PacSun D365 Integrations
  Built  : 2026-08-10   Validated against July 2026 + Aug 1-9 2026 production data
================================================================================

WHAT THIS FINDS
  Physical WM events that INT-00374 booked into inventory more than once.
  Two independent mechanisms exist and NO single rule catches both, so this
  detector has two arms that are mutually exclusive and additive:

  ARM 1  CROSS-COMBO TWIN  -- WM emitted 2+ DIFFERENT mapped PIX message types
         for one physical event, and both posted the same inventory effect.
         Catches: the e-comm returns double-book (604/02 + 606/04), the
         over/short lock twins (300/01/xx + 606/02/xx), and the 620 distro twins.
         Key   : same WM case + same item + same inventdimid (= warehouse +
                 WM bucket + colour + size) + IDENTICAL SIGNED qty, clustered
                 into one event by pacwmpxtran proximity (gap <= @gap).
         Excess: lines - MAX(lines for any single combo).  This is the count of
                 surplus COPIES.  It is NOT a pair count -- see NOTE A.

  ARM 2  SAME-COMBO RE-POST -- ONE PIX message produced 2-3 journal lines.
         This is a D365-side re-run of INT-00374, not a WM data problem
         (100% of these events span more than one journalid).
         Key   : the full PIX message key (txtp, txcd, accd, rscd, tran, casn),
                 which inventjournaltrans stamps in full on every line.
         Excess: journal lines booked - PIX messages WM actually sent.
         Arm 1 is structurally blind to this (its MAX-per-combo term absorbs
         the extra copy); Arm 2 is structurally blind to Arm 1. Hence two arms.

WHAT THIS DOES **NOT** FIND (accepted, documented blind spots)
  * A duplicate whose two legs land in DIFFERENT buckets or at DIFFERENT
    quantities. Requiring same inventdimid + same signed qty is exactly what
    separates a real double-book from a legitimate Active <-> Lock_Code move
    (328k such legitimate moves in July), so this is a deliberate trade.
  * Arm 1 only: PIX with a blank pacwmpxcasn (26,273 July lines, 2.7%).
    Arm 2 DOES cover them -- blank case is part of its key, not a filter.
  * Whether a duplicate was later reversed by MOV-DCSYNC or a counting journal.
    excess_cost is INVENTORY EXPOSURE, not a proven P&L loss. The returns
    family is known GL-neutral (credits 505000, debits 505840); the 620 family
    has NOT been traced to vouchers yet.

NOTE A -- WHY NOT A PAIRWISE SELF-JOIN
  The obvious implementation (self-join lines to lines) is WRONG. A return case
  holding 2-5 units of the same SKU produces n*(n-1) matches where only n are
  real, inflating the returns family by ~3.4% and the 620 family by up to 33%.
  This uses gap-and-islands windowing instead: no self-join, no fan-out.
  Proof it is right: Arm 1 returns 72,367 units / $909,247 for the returns
  family, landing on the independently-confirmed control total of
  72,397 units / $909,654 (0.04% = month-edge). The pairwise version returns
  74,863 / $939,408, i.e. it overstates a defect whose true size is known.

NOTE B -- SIGN-FLIP FAMILIES ARE UNDERSTATED BY DESIGN
  For 300/01/xx + 606/02/xx (ISS-00860 over/short sign flip) WM sent an
  offsetting S/A pair declaring NET ZERO. D365 booked both legs same-signed.
  excess_units here reports the surplus COPY (e.g. 20u); the true on-hand
  misstatement is DOUBLE that (40u), because the offsetting leg is also
  missing. Do not net these against the returns family.

NOTE C -- SERVERLESS GOTCHAS HONOURED
  'tran' is reserved -> aliased trn.  COLLATE DATABASE_DEFAULT on every
  cross-table string join.  IsDelete IS NULL for live rows (not 0).
  inventjournaltrans.createddatetime is the 1900-01-01 sentinel -> filter on
  transdate.  No STRING_AGG (blows the 8000-byte cap at this volume).
  pxinva scale is /10000 (empirically verified; the /1000 design doc is wrong).

TUNING
  @gap = 5 clusters journal lines into one physical event. Confirmed families
  sit at gap 0 (same pxtran) or gap 1 (adjacent). Widening re-admits
  coincidental collisions and lock/unlock ROUND TRIPS (a case locked then later
  unlocked is two legitimate same-dim same-sign legs). Any signature whose
  volume moves sharply between @gap=5 and @gap=100 is a window artifact, not a
  defect -- re-run with @gap=100 before believing a new signature.

KNOWN-BENIGN / UNCONFIRMED SIGNATURES (do not action without re-verifying)
  '300/01/06 + 608/12/06', '606/02/21 + 608/12/06', '606/02/06 + 608/12/06'
      -> window-unstable (2.6x-20x as @gap widens); 608/12 barely journals.
  '300/01/05 + 300/01/22'  -> 13 events, coincidental same-day collision.
==============================================================================*/

DECLARE @from date = '2026-07-01',      -- inclusive, journal transdate
        @to   date = '2026-08-01',      -- exclusive
        @gap  int  = 5;                 -- pacwmpxtran proximity for one event

WITH
/*--------------------------------------------------------------------------
  ARM 1 STEP 1: posted, PIX-stamped inventory journal lines with their dims.
  posted = 1 matters: this site has a history of unposted duplicate-ASN
  journals that would otherwise be counted as real double-books.
--------------------------------------------------------------------------*/
jl AS (
    SELECT  t.itemid,
            t.inventdimid,
            CAST(t.qty AS float)                                  AS qty,
            CAST(ABS(ISNULL(t.costamount,0)) AS float)            AS abscost,
            d.inventlocationid                                    AS whs,
            LTRIM(RTRIM(t.pacwmpxcasn))                           AS casn,
            TRY_CAST(t.pacwmpxtran AS bigint)                     AS trn,
            LTRIM(RTRIM(t.pacwmpxtxtp)) + '/' + LTRIM(RTRIM(t.pacwmpxtxcd)) + '/'
              + ISNULL(NULLIF(LTRIM(RTRIM(t.pacwmpxaccd)),''),'--')  AS combo
    FROM dbo.inventjournaltrans t
    JOIN dbo.inventjournaltable h
      ON  h.journalid  = t.journalid COLLATE DATABASE_DEFAULT
      AND h.dataareaid = t.dataareaid
      AND h.IsDelete IS NULL
      AND h.posted = 1
    JOIN dbo.inventdim d
      ON  d.inventdimid = t.inventdimid COLLATE DATABASE_DEFAULT
      AND d.dataareaid  = t.dataareaid
      AND d.IsDelete IS NULL
    WHERE t.dataareaid = '1001'
      AND t.IsDelete IS NULL
      AND t.transdate >= @from AND t.transdate < @to
      AND ISNULL(LTRIM(RTRIM(t.pacwmpxtxtp)),'') <> ''      -- PIX-sourced only
      AND ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'') <> ''      -- case anchors the event
      AND TRY_CAST(t.pacwmpxtran AS bigint) IS NOT NULL
),
/*  STEP 2: gap-and-islands. Inside one (case, item, dim, signed qty) cell,
    start a new physical event whenever the pxtran jumps more than @gap.     */
isl AS (
    SELECT *,
           CASE WHEN trn - LAG(trn) OVER (PARTITION BY casn,itemid,inventdimid,qty
                                          ORDER BY trn) > @gap
                  OR LAG(trn) OVER (PARTITION BY casn,itemid,inventdimid,qty
                                    ORDER BY trn) IS NULL
                THEN 1 ELSE 0 END AS newev
    FROM jl
),
ev AS (
    SELECT *,
           SUM(newev) OVER (PARTITION BY casn,itemid,inventdimid,qty ORDER BY trn
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS evno
    FROM isl
),
/*  STEP 3: collapse to one row per (event, PIX combo) so we can measure how
    many copies each combo contributed.                                      */
pc AS (
    SELECT casn, itemid, inventdimid, qty, evno, combo,
           COUNT_BIG(*) AS n, SUM(abscost) AS abscost, MAX(whs) AS whs
    FROM ev
    GROUP BY casn, itemid, inventdimid, qty, evno, combo
),
/*  STEP 4: the duplicate test. ncombos >= 2 means two different WM message
    types booked the identical inventory effect. maxn is the legitimate copy
    count (one physical unit per line); everything above it is surplus.       */
agg AS (
    SELECT casn, itemid, inventdimid, qty, evno,
           SUM(n)        AS nlines,
           COUNT_BIG(*)  AS ncombos,
           MAX(n)        AS maxn,
           SUM(abscost)  AS abscost,
           MAX(whs)      AS whs,
           MIN(combo)    AS c1,
           MAX(combo)    AS c2
    FROM pc
    GROUP BY casn, itemid, inventdimid, qty, evno
),
/*--------------------------------------------------------------------------
  ARM 2 STEP 1: what WM actually SENT, at the full PIX message key.
  The EXISTS on the mapping table is a PERFORMANCE pre-filter only (3-column,
  deliberately over-inclusive). Correctness comes from the inner join to the
  journal below: an unmapped reason code produces no journal line, so it
  cannot create a false positive. The mapping table is 64 rows = 48 '*'
  wildcards + 16 reason-code-specific rows, all of them 620/01/03 and
  620/02/03; the pxrscd = NULL rows match BLANK reason code only, they are
  NOT catch-alls (verified: 620/02/03 rscd 'CA' = 10,640 messages -> 0 lines).
--------------------------------------------------------------------------*/
px AS (
    SELECT  LTRIM(RTRIM(p.pxtxtp))                  AS txtp,
            LTRIM(RTRIM(p.pxtxcd))                  AS txcd,
            ISNULL(LTRIM(RTRIM(p.pxaccd)),'')       AS accd,
            ISNULL(LTRIM(RTRIM(p.pxrscd)),'')       AS rscd,
            TRY_CAST(p.pxtran AS bigint)            AS trn,
            ISNULL(LTRIM(RTRIM(p.pxcasn)),'')       AS casn,
            COUNT_BIG(*)                            AS npx,
            -- pxinat 'S' = subtract, 'A' = add;  pxinva scale = /10000
            SUM(CASE WHEN p.pxinat = 'S' THEN -1.0 ELSE 1.0 END
                * TRY_CAST(p.pxinva AS bigint) / 10000.0) AS wm_units
    FROM dbo.pacwmpixmessage p
    WHERE p.IsDelete IS NULL
      -- pad wide: a journal posted early in the window can be driven by a PIX
      -- message that landed days earlier. Under-counting npx = false positive.
      AND p.createddatetime >= DATEADD(day,-14,@from)
      AND p.createddatetime <  DATEADD(day,  7,@to)
      AND TRY_CAST(p.pxtran AS bigint) IS NOT NULL
      AND EXISTS (SELECT 1
                  FROM dbo.pacwmpixtransactionmappingtable m
                  WHERE m.IsDelete IS NULL AND m.dataareaid = '1001'
                    AND LTRIM(RTRIM(m.pxtxtp)) = LTRIM(RTRIM(p.pxtxtp)) COLLATE DATABASE_DEFAULT
                    AND LTRIM(RTRIM(m.pxtxcd)) = LTRIM(RTRIM(p.pxtxcd)) COLLATE DATABASE_DEFAULT
                    AND ISNULL(LTRIM(RTRIM(m.pxaccd)),'')
                      = ISNULL(LTRIM(RTRIM(p.pxaccd)),'') COLLATE DATABASE_DEFAULT)
    GROUP BY LTRIM(RTRIM(p.pxtxtp)), LTRIM(RTRIM(p.pxtxcd)),
             ISNULL(LTRIM(RTRIM(p.pxaccd)),''), ISNULL(LTRIM(RTRIM(p.pxrscd)),''),
             TRY_CAST(p.pxtran AS bigint), ISNULL(LTRIM(RTRIM(p.pxcasn)),'')
),
/*  ARM 2 STEP 2: what D365 actually BOOKED, at the same key.                */
jt AS (
    SELECT  LTRIM(RTRIM(t.pacwmpxtxtp))             AS txtp,
            LTRIM(RTRIM(t.pacwmpxtxcd))             AS txcd,
            ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),'')  AS accd,
            ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),'')  AS rscd,
            TRY_CAST(t.pacwmpxtran AS bigint)       AS trn,
            ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'')  AS casn,
            COUNT_BIG(*)                            AS njl,
            COUNT(DISTINCT t.journalid)             AS njrn,
            SUM(CAST(t.qty AS float))               AS d_units,
            SUM(ABS(CAST(ISNULL(t.costamount,0) AS float))) AS abscost
    FROM dbo.inventjournaltrans t
    JOIN dbo.inventjournaltable h
      ON  h.journalid  = t.journalid COLLATE DATABASE_DEFAULT
      AND h.dataareaid = t.dataareaid
      AND h.IsDelete IS NULL
      AND h.posted = 1
    WHERE t.dataareaid = '1001'
      AND t.IsDelete IS NULL
      AND t.transdate >= @from AND t.transdate < @to
      AND TRY_CAST(t.pacwmpxtran AS bigint) IS NOT NULL
    GROUP BY LTRIM(RTRIM(t.pacwmpxtxtp)), LTRIM(RTRIM(t.pacwmpxtxcd)),
             ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),''), ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),''),
             TRY_CAST(t.pacwmpxtran AS bigint), ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'')
)
/*============================ RESULT ======================================*/
SELECT  'ARM1 cross-combo twin'  AS arm,
        a.c1 + ' + ' + a.c2 + CASE WHEN a.ncombos > 2 THEN ' (+more)' ELSE '' END AS signature,
        a.whs,
        COUNT_BIG(*)                                                    AS events,
        SUM(a.nlines)                                                   AS journal_lines,
        SUM(a.nlines - a.maxn)                                          AS excess_lines,
        CAST(SUM((a.nlines - a.maxn) * ABS(a.qty))        AS decimal(18,0)) AS excess_units,
        CAST(SUM(a.abscost * (a.nlines - a.maxn) / a.nlines) AS decimal(18,0)) AS excess_cost,
        NULL                                                            AS pct_multi_journal
FROM agg a
WHERE a.ncombos >= 2
GROUP BY a.c1, a.c2, CASE WHEN a.ncombos > 2 THEN ' (+more)' ELSE '' END, a.whs

UNION ALL

SELECT  'ARM2 same-combo re-post' AS arm,
        j.txtp + '/' + j.txcd + '/' + ISNULL(NULLIF(j.accd,''),'--')    AS signature,
        NULL                                                            AS whs,
        COUNT_BIG(*)                                                    AS events,
        SUM(j.njl)                                                      AS journal_lines,
        SUM(j.njl - p.npx)                                              AS excess_lines,
        -- WM's own declared magnitude vs what D365 booked. Sign-agnostic so
        -- the ISS-00860 flip cannot hide a surplus copy.
        CAST(SUM(ABS(j.d_units) - ABS(p.wm_units))        AS decimal(18,0)) AS excess_units,
        CAST(SUM(j.abscost * (j.njl - p.npx) / j.njl)     AS decimal(18,0)) AS excess_cost,
        -- 100% here = INT-00374 re-ran and posted the same message into a new
        -- journal. Anything materially below 100% deserves a second look.
        CAST(100.0 * SUM(CASE WHEN j.njrn > 1 THEN 1 ELSE 0 END) / COUNT_BIG(*) AS decimal(5,1))
FROM jt j
JOIN px p
  ON  p.txtp = j.txtp COLLATE DATABASE_DEFAULT
  AND p.txcd = j.txcd COLLATE DATABASE_DEFAULT
  AND p.accd = j.accd COLLATE DATABASE_DEFAULT
  AND p.rscd = j.rscd COLLATE DATABASE_DEFAULT
  AND p.casn = j.casn COLLATE DATABASE_DEFAULT
  AND p.trn  = j.trn
WHERE j.njl > p.npx                              -- more lines than messages, AND
  AND ABS(j.d_units) > ABS(p.wm_units) + 0.0001  -- more UNITS than WM declared.
  /* Both conditions are required. njl > npx alone also fires on the legitimate
     case where INT-00374 SPLITS one message across buckets: more lines, but the
     units still tie out (or come in under). Those rows show NEGATIVE excess and
     pct_multi_journal = 0% -- one journal, one message, several lines. That is
     exactly what the whole 608/12/xx family does (608/12/06 -3,244 u @ 1.0%,
     608/12/05 -1,795 @ 0%, 608/12/19 -1,011 @ 0%, 608/12/20 -709 @ 0%), which
     is the third independent refutation of "608/12 is a double-book twin".   */
GROUP BY j.txtp, j.txcd, ISNULL(NULLIF(j.accd,''),'--')

ORDER BY excess_units DESC;

/*==============================================================================
  BASELINE -- July 2026 (@from 2026-07-01, @to 2026-08-01, @gap 5)
  ARM 1 total  117,005 excess units / $1,465,468 across 21 signatures
     604/02 + 606/04            4905   72,367 u   $909,247   (returns, defect 1)
     300/01/05|06|19|20 + 606/02 both  30,417 u   $393,001   (lock twin, defect 2)
     3xx + 620/0x/03            4901   12,108 u   $134,768   (NEW, see below)
     608/12/06 family           both    1,936 u    $25,316   (window artifact)
     300/01/05 + 300/01/22      4905      177 u     $3,136   (coincidence)
  ARM 2 total   68,892 excess units /   $793,617 across 25 combos, 100% of
                events spanning >1 journalid. Largest: 300/01/19 11,516 u,
                606/02/19 11,460 u, 300/01/99 10,793 u, 606/02/20 8,972 u.
                Note 604/02 and 606/04 each appear here too (672 events / 960 u):
                part of the returns overstatement is NOT the 604-vs-606 pair at
                all, it is the same message posted twice. Arm 1 cannot see that.
  Whole query runs in ~49 s for a full month. Safe to schedule nightly for the
  prior day (seconds at that volume).
                NB much of Arm 2 self-washes on NET on-hand (the re-posted pair
                is a balanced Active<->Lock_Code move) -- ~24k units is the net
                misstatement -- but the BUCKET split is corrupted either way,
                which is what breaks DC-sync reconciliation.

  STILL LIVE as of Aug 1-9 2026 (re-run with @from 2026-08-01):
     604/02 + 606/04     13,983 u / $179,123   -- returns, unfixed
     3xx + 620/0x/03      6,822 u /  $77,297   -- ~$8.6K/day, ~$3.1M/yr
     lock twins               0 u        $0    -- DORMANT since ~2026-07-25;
                                                  confirm whether ISS-00860 was
                                                  fixed or activity just stopped
==============================================================================*/