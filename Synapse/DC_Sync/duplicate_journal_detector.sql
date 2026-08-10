/*==============================================================================
  DUPLICATE JOURNAL DETECTOR  ("same journal booked N times")
  Target : D365 F&O Synapse serverless  (dataverse_psprod_*)   READ-ONLY
  Author : PacSun D365 Integrations
  Built  : 2026-08-10   Validated against 2026-07-01 .. 2026-08-10 production
  Runtime: PART 1 ~10s for 6 weeks.  PART 2 ~70s over a 6-week @from/@to -
           narrow the window to a few days around the target journal to speed up.
================================================================================

VALIDATION (2026-07-01 .. 2026-08-10)
  35 clone groups, EVERY one MOV-DCADJ, EVERY copy POSTED. 8 groups are triples
  (booked 3x), 27 are pairs. Two independent confirmations were run:
    * the 2026-07-16 / 144-line group reproduces a hand-diff of the three
      exported journals exactly, including the PIX combo mix line for line;
    * the 2026-07-01 group was re-checked with a plain multiset comparison (no
      hashing at all) - zero disagreeing line keys across all three journals.
  PART 2 on the 7/16 group: 294 of 432 lines are n_pix_messages = 1 against
  n_journal_lines = 3. WM sent the message once; D365 booked it three times.

  cost_drift is the tell that separates these from anything else: where it is
  non-zero the copies were staged at different times and picked up a different
  running-average cost, which is why a naive "identical rows" diff misses them.

WHAT THIS FINDS
  Whole inventory journals that are content-clones of each other: two or three
  different journalids holding the SAME line set, driven by the SAME WM PIX
  messages. This is INT-00374 staging one batch of PIX messages more than once.

  Worked example that motivated this query (all three POSTED in production):
      INV-01143812 / INV-01143909 / INV-01143928
      144 lines each, net -174 u, gross 2,064 u, transdate 2026-07-16,
      identical item / dim / qty / PIX key on every line, cost differs only
      because each staging run picked up a different running-average cost:
      -$2,423.51 / -$2,204.33 / -$2,231.43.

HOW THE FINGERPRINT WORKS
  Per line we hash the physical identity of the movement:
      transdate | itemid | inventdimid | signed qty
      | pacwmpxtxtp | pacwmpxtxcd | pacwmpxaccd | pacwmpxrscd
      | pacwmpxtran | pacwmpxcasn        <-- the full six-part PIX message key
  COST IS DELIBERATELY EXCLUDED. Cost is the one thing that legitimately drifts
  between staging runs (running average moves), so hashing it would hide the
  duplicates instead of finding them. Cost is reported as a column instead.

  Per journal we roll those line hashes into an ORDER-INDEPENDENT fingerprint:
      nlines : SUM(qty) : SUM(hash) : MIN(hash) : MAX(hash)
  Order-independent matters because the re-staged journal does not have to emit
  its lines in the same sequence. SUM (not CHECKSUM_AGG) is used on purpose:
  CHECKSUM_AGG is XOR-based, so a journal holding two genuinely identical lines
  would cancel them to zero and collide with a journal that holds neither.

WHY pacwmpxtran IN THE KEY MAKES THIS SAFE
  pxtran is WM's own transaction id. Two physically distinct events cannot share
  a full set of pxtran + case + item + dim + qty values. That is what separates
  this from "two journals that happen to look alike" and is why this detector
  needs no tolerance/threshold tuning.

RELATIONSHIP TO pix_double_book_detector.sql
  Complementary, not overlapping. That query works at the EVENT grain and finds
  duplicated inventory effect wherever it lands (Arm 1 cross-combo twins,
  Arm 2 per-message re-posts). This one works at the JOURNAL grain and finds the
  coarser failure: an entire batch re-staged end to end. A batch-level clone
  shows up here as one obvious row instead of hundreds of Arm 2 rows.

SCOPE / CAVEATS
  * PIX-sourced lines only (pacwmpxtxtp non-blank). Non-PIX journals have no
    stable physical key to fingerprint on.
  * `posted` is REPORTED, not filtered. Unposted clones are the ones you can
    still delete, so you want to see them; posted clones are already GL.
  * A duplicate here is inventory EXPOSURE. Whether MOV-DCSYNC or a later
    counting journal reversed it is a separate question - see the DC-sync
    bucket-wash pattern before quoting surplus_cost as a P&L loss.
  * Serverless gotchas honoured: no VALUES-constructor CTE (UNION ALL instead),
    COLLATE DATABASE_DEFAULT on cross-table string joins, IsDelete IS NULL for
    live rows, inventjournaltrans.createddatetime is the 1900-01-01 sentinel so
    filtering is on transdate, SUM of hashes cast to decimal(38,0) because
    bigint overflows at this row count.
==============================================================================*/


/*============================================================================
  PART 1 - SUMMARY.  One row per duplicate group.
  Line count, total units, the journal numbers, and the PIX messages behind it.
============================================================================*/

DECLARE @from date = '2026-07-01',   -- inclusive, journal transdate
        @to   date = '2026-08-11';   -- exclusive

WITH
/*-- PIX Type/Code/ActionCode -> plain English (2014 processing matrix). ------*/
dec AS (
    SELECT '300' t,'01' c,'05' a,'Maintain Case - Lock Case'                              d
    UNION ALL SELECT '300','01','06','Maintain Case - Unlock Case'
    UNION ALL SELECT '300','01','07','Maintain Case - Consume Case'
    UNION ALL SELECT '300','01','08','Maintain Case - Modify Case Before Shipment Verf''n'
    UNION ALL SELECT '300','01','09','Maintain Case - Modify Case After Shipment Verf''n'
    UNION ALL SELECT '300','01','19','Maintain Case - Lock Case Before Shipment Verified'
    UNION ALL SELECT '300','01','20','Maintain Case - Unlock Case Before Shipment Verified'
    UNION ALL SELECT '300','01','22','Maintain Case - Case Co/Div Inventory Transfer'
    UNION ALL SELECT '300','01','24','Maintain Case - Consume Case Before Shipment Verf''n'
    UNION ALL SELECT '300','01','99','Maintain Case - (AC 99 not in 2014 matrix)'
    UNION ALL SELECT '300','02','',  'Maintain Carton'
    UNION ALL SELECT '300','04','',  'Maintain Active'
    UNION ALL SELECT '300','04','06','Maintain Active - Unlock Active'
    UNION ALL SELECT '300','04','14','Maintain Active - Cycle Count Adjustments'
    UNION ALL SELECT '300','04','20','Maintain Active - Unlock Case Before Shipment Verified'
    UNION ALL SELECT '604','02','',  'Returns Acknowledgement SKU Detail'
    UNION ALL SELECT '606','02','01','Unallocatable Case Inv Adj - Create Case'
    UNION ALL SELECT '606','02','05','Unallocatable Case Inv Adj - Lock Case'
    UNION ALL SELECT '606','02','06','Unallocatable Case Inv Adj - Unlock Case'
    UNION ALL SELECT '606','02','08','Unallocatable Case Inv Adj - Modify Before Shmt Verf''n'
    UNION ALL SELECT '606','02','09','Unallocatable Case Inv Adj - Modify After Shmt Verf''n'
    UNION ALL SELECT '606','02','19','Unallocatable Case Inv Adj - Lock Before Shmt Verified'
    UNION ALL SELECT '606','02','20','Unallocatable Case Inv Adj - Unlock Before Shmt Verified'
    UNION ALL SELECT '606','02','21','Unallocatable Case Inv Adj - Unlock for RTV Pickticket'
    UNION ALL SELECT '606','02','26','Unallocatable Case Inv Adj - Undo Receipt Before Shmt Verf'
    UNION ALL SELECT '606','02','27','Unallocatable Case Inv Adj - Undo Receipt After Shmt Verf'
    UNION ALL SELECT '606','04','',  'Returns: Unallocatable Inventory'
    UNION ALL SELECT '606','06','',  'Active: Unallocatable Inventory'
    UNION ALL SELECT '606','06','05','Active: Unallocatable Inventory - Lock Active'
    UNION ALL SELECT '606','06','06','Active: Unallocatable Inventory - Unlock Active'
    UNION ALL SELECT '606','06','14','Active: Unallocatable Inventory - Cycle Count Adjustments'
    UNION ALL SELECT '606','06','19','Active: Unallocatable Inventory - Lock Before Shmt Verified'
    UNION ALL SELECT '608','12','05','Lock Code Change On Case - Lock After Shmt Verified'
    UNION ALL SELECT '608','12','06','Lock Code Change On Case - Unlock After Shmt Verified'
    UNION ALL SELECT '608','12','19','Lock Code Change On Case - Lock Before Shmt Verified'
    UNION ALL SELECT '608','12','20','Lock Code Change On Case - Unlock Before Shmt Verified'
    UNION ALL SELECT '608','14','',  'Audit Carton'
    UNION ALL SELECT '620','01','03','Reserve Distro - Perpetual/Retail Pickticket Detail Update'
    UNION ALL SELECT '620','02','03','Receipt Distro - Perpetual/Retail Pickticket Detail Update'
    UNION ALL SELECT '901','01','19','(901/01/19 not in 2014 matrix)'
),
/*-- Step 1: PIX-stamped journal lines + per-line physical-identity hash. -----*/
jl AS (
    SELECT  t.journalid,
            h.journalnameid,
            h.posted,
            t.transdate,
            CAST(t.qty AS float)                    AS qty,
            CAST(ISNULL(t.costamount,0) AS float)   AS costamount,
            LTRIM(RTRIM(t.pacwmpxtxtp)) + '/' + LTRIM(RTRIM(t.pacwmpxtxcd)) + '/'
              + ISNULL(NULLIF(LTRIM(RTRIM(t.pacwmpxaccd)),''),'--')  AS combo,
            CONVERT(bigint, SUBSTRING(HASHBYTES('SHA2_256',
                CONCAT(CONVERT(char(8), t.transdate, 112),                     '|',
                       LTRIM(RTRIM(t.itemid)),                                 '|',
                       LTRIM(RTRIM(t.inventdimid)),                            '|',
                       CONVERT(varchar(30), CAST(t.qty AS decimal(28,6))),     '|',
                       LTRIM(RTRIM(t.pacwmpxtxtp)),                            '|',
                       LTRIM(RTRIM(t.pacwmpxtxcd)),                            '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),''),                 '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),''),                 '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxtran)),''),                 '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),''))
            ), 1, 7))                               AS lh
    FROM dbo.inventjournaltrans t
    JOIN dbo.inventjournaltable h
      ON  h.journalid  = t.journalid COLLATE DATABASE_DEFAULT
      AND h.dataareaid = t.dataareaid
      AND h.IsDelete IS NULL
    WHERE t.dataareaid = '1001'
      AND t.IsDelete IS NULL
      AND t.transdate >= @from AND t.transdate < @to
      AND ISNULL(LTRIM(RTRIM(t.pacwmpxtxtp)),'') <> ''      -- PIX-sourced only
),
/*-- Step 2: collapse each journal to one order-independent fingerprint. ------*/
jf AS (
    SELECT  journalid,
            MAX(journalnameid)  AS journalnameid,
            MAX(posted)         AS posted,
            MIN(transdate)      AS transdate,
            COUNT_BIG(*)        AS nlines,
            SUM(qty)            AS netqty,
            SUM(ABS(qty))       AS grossqty,
            SUM(costamount)     AS costamt,
            CONCAT(COUNT_BIG(*),                                     ':',
                   CONVERT(varchar(40), SUM(qty)),                   ':',
                   CONVERT(varchar(50), SUM(CONVERT(decimal(38,0), lh))), ':',
                   CONVERT(varchar(40), MIN(lh)),                    ':',
                   CONVERT(varchar(40), MAX(lh)))                    AS fp
    FROM jl
    GROUP BY journalid
),
/*-- Step 3: fingerprints held by more than one journalid = clones. ----------*/
dup AS (
    SELECT fp FROM jf GROUP BY fp HAVING COUNT(*) > 1
),
/*-- Step 4: the PIX messages behind each clone group, decoded. --------------*/
mix AS (
    SELECT  j.fp,
            l.combo,
            COUNT_BIG(*)                                    AS nlines,
            COUNT(DISTINCT LTRIM(RTRIM(l.journalid)))       AS njournals
    FROM jl l
    JOIN jf j ON j.journalid = l.journalid
    WHERE j.fp IN (SELECT fp FROM dup)
    GROUP BY j.fp, l.combo
),
pix AS (
    SELECT  m.fp,
            STRING_AGG(
                CONCAT(m.combo COLLATE DATABASE_DEFAULT, ' x',
                       m.nlines / m.njournals, ' (',
                       ISNULL(d.d,'?') COLLATE DATABASE_DEFAULT, ')')
                , '  |  ')
                WITHIN GROUP (ORDER BY m.combo)             AS pix_messages
    FROM mix m
    LEFT JOIN dec d
           ON d.t = LEFT(m.combo,3) COLLATE DATABASE_DEFAULT
          AND d.c = SUBSTRING(m.combo,5,2) COLLATE DATABASE_DEFAULT
          AND d.a = REPLACE(SUBSTRING(m.combo,8,2),'--','') COLLATE DATABASE_DEFAULT
    GROUP BY m.fp
)
SELECT
    CONVERT(char(10), MIN(f.transdate), 23)         AS transdate,
    MAX(f.journalnameid)                            AS journal_name,
    COUNT(*)                                        AS n_journals,      -- 2 = booked twice, 3 = three times
    SUM(CASE WHEN f.posted = 1 THEN 1 ELSE 0 END)   AS n_posted,
    MIN(f.nlines)                                   AS lines_per_journal,
    MIN(f.nlines) * (COUNT(*) - 1)                  AS surplus_lines,
    MIN(f.netqty)                                   AS net_units_each,
    MIN(f.grossqty)                                 AS gross_units_each,
    MIN(f.netqty)   * (COUNT(*) - 1)                AS surplus_net_units,
    MIN(f.grossqty) * (COUNT(*) - 1)                AS surplus_gross_units,
    ROUND(MIN(f.costamt), 2)                        AS cost_min,
    ROUND(MAX(f.costamt), 2)                        AS cost_max,
    ROUND(MAX(f.costamt) - MIN(f.costamt), 2)       AS cost_drift,       -- >0 confirms separate staging runs
    ROUND(SUM(f.costamt) - MIN(f.costamt), 2)       AS surplus_cost,     -- exposure = all copies but one
    STRING_AGG(f.journalid COLLATE DATABASE_DEFAULT, ', ')
        WITHIN GROUP (ORDER BY f.journalid)         AS journal_ids,
    MAX(p.pix_messages)                             AS pix_messages,     -- combo xN (decoded), per copy
    MIN(f.fp)                                       AS fingerprint       -- feed to PART 2
FROM jf f
JOIN dup   ON dup.fp = f.fp
LEFT JOIN pix p ON p.fp = f.fp
GROUP BY f.fp
ORDER BY surplus_cost DESC;


/*============================================================================
  PART 2 - LINE DETAIL FOR ONE GROUP, WITH THE RAW PIX MESSAGE.

  Set @journalid to any journal from PART 2's journal_ids. This pulls every
  copy of that journal, line by line, joined on the full six-part PIX key to
  the message WM actually sent.

  READ THE COLUMNS THIS WAY
    n_journal_lines vs n_pix_messages on the same key is the proof:
    WM sent the message ONCE (n_pix_messages = 1) and D365 booked it
    n_journal_lines times. If both numbers move together, it is not a re-stage
    - it is WM genuinely re-sending, and belongs to pix_double_book_detector.
============================================================================*/
/*
DECLARE @from date = '2026-07-01',
        @to   date = '2026-08-11',
        @journalid varchar(20) = 'INV-01143812';

WITH jl AS (
    SELECT  t.journalid, h.posted, t.transdate, t.linenum,
            t.itemid, t.inventdimid,
            CAST(t.qty AS float)                  AS qty,
            CAST(ISNULL(t.costprice,0)  AS float) AS costprice,
            CAST(ISNULL(t.costamount,0) AS float) AS costamount,
            LTRIM(RTRIM(t.pacwmpxtxtp))           AS txtp,
            LTRIM(RTRIM(t.pacwmpxtxcd))           AS txcd,
            ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),'') AS accd,
            ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),'') AS rscd,
            ISNULL(LTRIM(RTRIM(t.pacwmpxtran)),'') AS trn,
            ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'') AS casn,
            CONVERT(bigint, SUBSTRING(HASHBYTES('SHA2_256',
                CONCAT(CONVERT(char(8), t.transdate, 112), '|',
                       LTRIM(RTRIM(t.itemid)), '|', LTRIM(RTRIM(t.inventdimid)), '|',
                       CONVERT(varchar(30), CAST(t.qty AS decimal(28,6))), '|',
                       LTRIM(RTRIM(t.pacwmpxtxtp)), '|', LTRIM(RTRIM(t.pacwmpxtxcd)), '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),''), '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),''), '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxtran)),''), '|',
                       ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),''))), 1, 7)) AS lh
    FROM dbo.inventjournaltrans t
    JOIN dbo.inventjournaltable h
      ON h.journalid = t.journalid COLLATE DATABASE_DEFAULT
     AND h.dataareaid = t.dataareaid AND h.IsDelete IS NULL
    WHERE t.dataareaid='1001' AND t.IsDelete IS NULL
      AND t.transdate >= @from AND t.transdate < @to
      AND ISNULL(LTRIM(RTRIM(t.pacwmpxtxtp)),'') <> ''
),
jf AS (
    SELECT journalid,
           CONCAT(COUNT_BIG(*), ':', CONVERT(varchar(40), SUM(qty)), ':',
                  CONVERT(varchar(50), SUM(CONVERT(decimal(38,0), lh))), ':',
                  CONVERT(varchar(40), MIN(lh)), ':', CONVERT(varchar(40), MAX(lh))) AS fp
    FROM jl GROUP BY journalid
),
grp AS (   -- every journal sharing the target journal's fingerprint
    SELECT journalid FROM jf
    WHERE fp = (SELECT fp FROM jf WHERE journalid = @journalid COLLATE DATABASE_DEFAULT)
),
-- what WM actually sent on each PIX key (pxinva scale = /10000, pxinat S = subtract)
px AS (
    SELECT  LTRIM(RTRIM(p.pxtxtp)) AS txtp, LTRIM(RTRIM(p.pxtxcd)) AS txcd,
            ISNULL(LTRIM(RTRIM(p.pxaccd)),'') AS accd,
            ISNULL(LTRIM(RTRIM(p.pxrscd)),'') AS rscd,
            ISNULL(LTRIM(RTRIM(p.pxtran)),'') AS trn,
            ISNULL(LTRIM(RTRIM(p.pxcasn)),'') AS casn,
            COUNT_BIG(*)   AS n_pix_messages,
            SUM(CASE WHEN p.pxinat='S' THEN -1.0 ELSE 1.0 END
                * TRY_CAST(p.pxinva AS bigint) / 10000.0) AS wm_units,
            MAX(p.pxlfid)  AS pxlfid,      -- R=Reserve C=Active L=Case-Pick
            MAX(p.pxinvi)  AS pxinvi,      -- 'Y' = WM says this leg hits inventory
            MAX(p.pxdcr)   AS px_wm_date,  -- Eastern
            MAX(p.pxtcr)   AS px_wm_time,
            MAX(p.message) AS px_message   -- -> sunintmessage, traces to the source file
    FROM dbo.pacwmpixmessage p
    WHERE p.IsDelete IS NULL
      AND p.createddatetime >= DATEADD(day,-14,@from)
      AND p.createddatetime <  DATEADD(day,  7,@to)
    GROUP BY LTRIM(RTRIM(p.pxtxtp)), LTRIM(RTRIM(p.pxtxcd)),
             ISNULL(LTRIM(RTRIM(p.pxaccd)),''), ISNULL(LTRIM(RTRIM(p.pxrscd)),''),
             ISNULL(LTRIM(RTRIM(p.pxtran)),''), ISNULL(LTRIM(RTRIM(p.pxcasn)),'')
)
SELECT  l.journalid, l.posted, CONVERT(char(10), l.transdate, 23) AS transdate,
        l.itemid, d.inventcolorid AS colorid, d.inventsizeid AS sizeid,
        d.inventlocationid AS whs, d.wmslocationid AS bucket,
        l.qty, l.costprice, l.costamount,
        l.txtp + '/' + l.txcd + '/' + NULLIF(l.accd,'') AS pix_combo,
        l.rscd AS pix_reason, l.trn AS pxtran, l.casn AS wm_case,
        x.n_pix_messages,                                   -- WM sent this many
        COUNT(*) OVER (PARTITION BY l.lh)  AS n_journal_lines,  -- D365 booked this many
        x.wm_units, x.pxlfid, x.pxinvi, x.px_wm_date, x.px_wm_time, x.px_message
FROM jl l
JOIN grp g ON g.journalid = l.journalid
JOIN dbo.inventdim d
  ON d.inventdimid = l.inventdimid COLLATE DATABASE_DEFAULT
 AND d.dataareaid = '1001' AND d.IsDelete IS NULL
LEFT JOIN px x
  ON  x.txtp = l.txtp COLLATE DATABASE_DEFAULT AND x.txcd = l.txcd COLLATE DATABASE_DEFAULT
  AND x.accd = l.accd COLLATE DATABASE_DEFAULT AND x.rscd = l.rscd COLLATE DATABASE_DEFAULT
  AND x.trn  = l.trn  COLLATE DATABASE_DEFAULT AND x.casn = l.casn COLLATE DATABASE_DEFAULT
ORDER BY l.itemid, l.casn, l.qty, l.journalid;
*/
