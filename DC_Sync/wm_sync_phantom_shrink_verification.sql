-- ============================================================================
-- WM DAILY SYNC PHANTOM SHRINK — VERIFICATION QUERIES
-- Companion to: WM_Sync_PhantomShrink_Report_2026-07-01.pdf
--
-- FINDING: The 6/30/2026 COU-DCSYNC journal batch (-113,199 units, INV-00929833
-- alone -94,348 / ~$993K) is a measurement artifact, not real shrink. WM's total
-- physical count was flat (+2,030 units) between the 6/29 and 6/30 snapshots.
-- The 605 DailyInvSync counts only Active/Lock_Code buckets; at quarter-end the
-- volume of inventory IN FLIGHT inside the building (staged outbound whose carton
-- invoices post after the nightly journal; received freight not yet putaway)
-- exploded, and every in-flight unit reads as phantom shrink.
--
-- Run against: Synapse Serverless (DBeaver connection "D365-Production")
--   Server:   d365-synapse-ps-prod-ondemand.sql.azuresynapse.net
--   Database: dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- All output times converted to PST/PDT. Raw Dataverse datetimes are UTC.
-- WM's own PIX timestamps (PXDCR/PXTCR) are WM's iSeries clock = EASTERN.
-- ============================================================================


-- ============================================================================
-- Q1. JOURNAL BATCH TOTALS — reproduces the D365 journal screen numbers
-- Expected (6/29): -300 / -1,331 / -7,510 / -1,311  (total -10,452)
-- Expected (6/30): -94,348 / -2,254 / -6,635 / -9,962 (total -113,199)
-- Note the gross columns on INV-00929833: -534,764 shrink vs +440,416 found
-- = net -94,348. The huge offsetting gross is the Active/Lock_Code bucket wash.
-- ============================================================================
SELECT jt.journalid,
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS night_pst,
    jt.numoflines,
    SUM(jtr.qty) AS net_units,
    SUM(CASE WHEN jtr.qty < 0 THEN jtr.qty ELSE 0 END) AS gross_shrink,
    SUM(CASE WHEN jtr.qty > 0 THEN jtr.qty ELSE 0 END) AS gross_found
FROM dbo.InventJournalTable jt
INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
    AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
WHERE jt.journalnameid='COU-DCSYNC' AND jt.IsDelete IS NULL
  AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
      IN ('2026-06-29','2026-06-30')
GROUP BY jt.journalid,
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
    jt.numoflines
ORDER BY night_pst, jt.journalid;


-- ============================================================================
-- Q2. WM TOTAL COUNTED UNITS PER SNAPSHOT — proves physical inventory was FLAT
-- Expected: 6/29 = 2,691,944 total (4901: 742,503 + 4905: 1,949,441)
--           6/30 = 2,693,974 total (4901: 715,499 + 4905: 1,978,475)
--           Delta = +2,030 units while the journal claimed -113K shrink.
-- ============================================================================
SELECT SUBSTRING(pxdcr,3,8) AS snap_date, inventlocationid,
    SUM(CAST(wmcount AS DECIMAL(18,4))) AS wm_total_units,
    COUNT(DISTINCT itemid) AS distinct_items
FROM dbo.pacwmcounts
WHERE IsDelete IS NULL
  AND pxdcr IN ('020260628','020260629','020260630')
GROUP BY SUBSTRING(pxdcr,3,8), inventlocationid
ORDER BY snap_date, inventlocationid;


-- ============================================================================
-- Q3. DAILY PO RECEIPT VOLUME — the quarter-end receiving surge
-- Expected: 6/27: ~6K → 6/29: ~149K → 6/30: ~173K → 7/1: ~154K units/day.
-- The nightly phantom-shrink magnitude tracks this volume.
-- ============================================================================
SELECT CAST(t.datephysical AS DATE) AS receipt_date,
    SUM(t.qty) AS receipt_units,
    COUNT(DISTINCT t.itemid) AS distinct_items
FROM dbo.inventtransorigin o
INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4902','4905')
  AND o.referencecategory = 3          -- Purch (PO receipts)
  AND t.datephysical >= '2026-06-24' AND t.datephysical <= '2026-07-02'
GROUP BY CAST(t.datephysical AS DATE)
ORDER BY receipt_date;


-- ============================================================================
-- Q4. TIMELINE PROOF — WM snapshot generation vs D365 parse vs journal creation
-- PXTCR is WM's iSeries clock (EASTERN). Expected: WM generates 23:30-23:49 ET;
-- D365 parses ~9:35-10:27 PM PDT (= 00:35-01:27 ET); journals created
-- 10:28-11:05 PM PDT. Clock gap snapshot->journal is only ~2 quiet hours.
-- ============================================================================
SELECT p.pxdcr,
    MIN(p.pxtcr) AS wm_gen_start_ET_hhmmss,
    MAX(p.pxtcr) AS wm_gen_end_ET_hhmmss,
    MIN(p.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS d365_parse_start_pst,
    MAX(p.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS d365_parse_end_pst,
    COUNT(*) AS pix_lines
FROM dbo.pacwmpixmessage p
WHERE p.IsDelete IS NULL AND p.pxtxtp='605'
  AND p.pxdcr IN ('020260628','020260629','020260630')
GROUP BY p.pxdcr
ORDER BY p.pxdcr;

-- Journal creation times for the same nights:
SELECT journalid,
    createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS created_pst
FROM dbo.InventJournalTable
WHERE journalnameid='COU-DCSYNC' AND IsDelete IS NULL
  AND createddatetime >= '2026-06-29T00:00:00'
ORDER BY createddatetime;


-- ============================================================================
-- Q5. CTN-TRANSFER POSTING WAVES BY HOUR — outbound posts AFTER the journal
-- Expected: big invoice waves at 00:00-03:00 PDT (03:00-06:00 ET) each night —
-- i.e., AFTER the ~10:30 PM journal. Units staged/picked before the snapshot
-- remain in D365 on-hand at journal time -> phantom shrink.
-- ============================================================================
SELECT
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS day_pst,
    DATEPART(HOUR, jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS hour_pst,
    COUNT(DISTINCT jt.journalid) AS journals,
    SUM(jtr.qty) AS net_units
FROM dbo.InventJournalTable jt
INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
    AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
WHERE jt.journalnameid='CTN-TRANSFER' AND jt.IsDelete IS NULL
  AND jt.createddatetime >= '2026-06-29T07:00:00'   -- 6/29 00:00 PDT
GROUP BY CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
    DATEPART(HOUR, jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time')
ORDER BY day_pst, hour_pst;


-- ============================================================================
-- Q6. DECOMPOSITION OF THE 6/29 -> 6/30 JUMP (key = item + inventdim)
-- Expected:
--   BOTH_NIGHTS  (~12,347 keys): qty -11,335 -> -71,312 (delta -59,977).
--       WM counted fell -74,168 while D365 on-hand fell only -14,191
--       = staged outbound (picked for the month-end store push, carton
--         invoices not yet posted).
--   ONLY_6/30_NEW (~6,617 keys): -41,887. Receipt-wave keys where D365
--       on-hand (459,786) exceeds WM counted (417,899) = received freight
--       posted to D365 but not yet in WM counted buckets.
--   ONLY_6/29_DROPPED (~1,100 keys): -883 (negligible).
-- ============================================================================
WITH j29 AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
           jtr.inventdimid COLLATE DATABASE_DEFAULT AS dimid,
        SUM(jtr.qty) AS qty29, SUM(jtr.counted) AS counted29,
        SUM(jtr.counted - jtr.qty) AS onhand29
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    WHERE jt.journalnameid='COU-DCSYNC' AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)='2026-06-29'
    GROUP BY jtr.itemid, jtr.inventdimid
),
j30 AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
           jtr.inventdimid COLLATE DATABASE_DEFAULT AS dimid,
        SUM(jtr.qty) AS qty30, SUM(jtr.counted) AS counted30,
        SUM(jtr.counted - jtr.qty) AS onhand30
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    WHERE jt.journalnameid='COU-DCSYNC' AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)='2026-06-30'
    GROUP BY jtr.itemid, jtr.inventdimid
)
SELECT
    CASE WHEN j29.itemid IS NOT NULL AND j30.itemid IS NOT NULL THEN 'BOTH_NIGHTS'
         WHEN j30.itemid IS NOT NULL THEN 'ONLY_6/30_NEW'
         ELSE 'ONLY_6/29_DROPPED' END AS key_category,
    COUNT(*) AS keys_cnt,
    SUM(ISNULL(j29.qty29,0))  AS qty_629,
    SUM(ISNULL(j30.qty30,0))  AS qty_630,
    SUM(ISNULL(j30.qty30,0)) - SUM(ISNULL(j29.qty29,0)) AS delta_qty,
    SUM(ISNULL(j30.counted30,0)) - SUM(ISNULL(j29.counted29,0)) AS delta_wm_counted,
    SUM(ISNULL(j30.onhand30,0)) - SUM(ISNULL(j29.onhand29,0))  AS delta_d365_onhand
FROM j29
FULL OUTER JOIN j30 ON j30.itemid = j29.itemid AND j30.dimid = j29.dimid
GROUP BY CASE WHEN j29.itemid IS NOT NULL AND j30.itemid IS NOT NULL THEN 'BOTH_NIGHTS'
         WHEN j30.itemid IS NOT NULL THEN 'ONLY_6/30_NEW'
         ELSE 'ONLY_6/29_DROPPED' END;


-- ============================================================================
-- Q7. SINGLE-ITEM DRILLDOWN — swap @item to verify any example from the report
-- Example expectations for 0097-60326-0554 (staged-outbound case):
--   WM count 4901: 6/26: 6,709 -> 6/29: 5,565 -> 6/30: 1,025 (collapse)
--   D365 6/28-7/1: PO receipts 0 (its +8,627 receipt was 6/26),
--       CTN-TRANSFER posted only -2,120 in the window, sales -275
--   6/30 sync line: net -3,817 (units staged for stores, invoices lagging)
-- Other examples: '0704-60160-1940' (ASN-overage receipt +6,444; wash
--   -8,510 Active / +6,444 Lock_Code), '0131-45421-0179' (+4,998 FOUND:
--   WM counted 7,508 before D365 posted all receipts), '0120-46868-0652'
--   (style family staged: 722 -> 211 with almost no D365 outbound).
-- ============================================================================
DECLARE @item VARCHAR(20) = '0097-60326-0554';

-- 7a. WM nightly count trend by warehouse/bucket
SELECT SUBSTRING(pxdcr,3,8) AS snap_date, inventlocationid, wmslocationid,
    SUM(CAST(wmcount AS DECIMAL(18,4))) AS wm_units
FROM dbo.pacwmcounts
WHERE IsDelete IS NULL AND itemid = @item AND pxdcr >= '020260626'
GROUP BY SUBSTRING(pxdcr,3,8), inventlocationid, wmslocationid
ORDER BY snap_date, inventlocationid, wmslocationid;

-- 7b. Its COU-DCSYNC journal lines (counted vs implied on-hand), by night
SELECT CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS night_pst,
    jt.journalid, d.inventlocationid, d.wmslocationid, d.inventsizeid,
    jtr.counted, jtr.qty, jtr.counted - jtr.qty AS implied_d365_onhand
FROM dbo.InventJournalTrans jtr
INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001'
WHERE jt.journalnameid='COU-DCSYNC' AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
  AND jtr.itemid = @item
  AND jt.createddatetime >= '2026-06-29T00:00:00'
ORDER BY night_pst, d.inventlocationid, d.wmslocationid, d.inventsizeid;

-- 7c. Every D365 transaction category for it, 6/28-7/1
SELECT CAST(t.datephysical AS DATE) AS trans_date,
    CASE o.referencecategory
        WHEN 0 THEN 'Sales' WHEN 3 THEN 'PO_Receipt' WHEN 4 THEN 'MOV_journal'
        WHEN 6 THEN 'CTN_TRANSFER' WHEN 13 THEN 'COU_DCSYNC'
        ELSE CONCAT('RefCat_', o.referencecategory) END AS category,
    COUNT(*) AS trans_cnt, SUM(t.qty) AS net_qty
FROM dbo.inventtransorigin o
INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4902','4905')
  AND t.itemid = @item
  AND t.datephysical >= '2026-06-28' AND t.datephysical <= '2026-07-01'
GROUP BY CAST(t.datephysical AS DATE), o.referencecategory
ORDER BY trans_date, category;


-- ============================================================================
-- Q8. RECEIPTS POSTED BETWEEN THE TWO JOURNAL RUNS (the in-window instrument)
-- Window boundaries in UTC: 6/29 10:36 PM PDT = 2026-06-30T05:36Z;
--                           6/30 10:36 PM PDT = 2026-07-01T05:36Z.
-- Expected: ~146K receipt units posted into D365 between the runs
-- (modifieddatetime used as posting-time proxy; createddatetime on
-- InventTrans is PO-creation time, NOT posting time).
-- ============================================================================
SELECT
    CASE
        WHEN t.modifieddatetime < '2026-06-30T05:36:00' THEN '1_before_6/29_journal'
        WHEN t.modifieddatetime < '2026-07-01T05:36:00' THEN '2_between_journals'
        ELSE '3_after_6/30_journal'
    END AS posting_window,
    CAST(t.datephysical AS DATE) AS receipt_date,
    SUM(t.qty) AS receipt_units
FROM dbo.inventtransorigin o
INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4902','4905')
  AND o.referencecategory = 3
  AND t.datephysical >= '2026-06-28' AND t.datephysical <= '2026-07-01'
GROUP BY
    CASE
        WHEN t.modifieddatetime < '2026-06-30T05:36:00' THEN '1_before_6/29_journal'
        WHEN t.modifieddatetime < '2026-07-01T05:36:00' THEN '2_between_journals'
        ELSE '3_after_6/30_journal'
    END,
    CAST(t.datephysical AS DATE)
ORDER BY posting_window, receipt_date;


-- ============================================================================
-- Q9. ONGOING MONITOR — nightly journal net vs same-day flow volume
-- Run any time. If |journal net| tracks allocation + receipt volume, the
-- shrink is flow artifact, not loss. Watch it normalize after quarter-end.
-- VALIDATED 2026-07-01: the two shrink spikes align with the two biggest
-- allocation days of the month, and the 6/26 spike SELF-REVERSED overnight:
--   6/22-6/25: alloc 198-233K/day -> journal nets only -2K..-9K (steady state)
--   6/26: alloc 256,846 -> journal net -144,083   <- spike
--   6/27: alloc  54,938 -> journal net   -8,668   <- reversed itself; no
--         journal was posted in between. Real shrink cannot do this.
--   6/29: alloc 171,958 -> journal net  -10,452
--   6/30: alloc 317,821 -> journal net -113,199   <- month-end monster wave
-- Nightly journal net ~= -(in-flight population at snapshot) which breathes
-- with the allocation/receiving waves.
-- ============================================================================
WITH nightly_journal AS (
    SELECT CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS d,
        SUM(jtr.qty) AS journal_net_units
    FROM dbo.InventJournalTable jt
    INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
        AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
    WHERE jt.journalnameid='COU-DCSYNC' AND jt.IsDelete IS NULL
      AND jt.createddatetime >= DATEADD(DAY,-21,GETUTCDATE())
    GROUP BY CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
),
daily_receipts AS (
    SELECT CAST(t.datephysical AS DATE) AS d, SUM(t.qty) AS receipt_units
    FROM dbo.inventtransorigin o
    INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
    INNER JOIN dbo.inventdim dd ON dd.inventdimid = t.inventdimid AND dd.dataareaid='1001'
    WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
      AND dd.inventlocationid IN ('4901','4902','4905') AND o.referencecategory = 3
      AND t.datephysical >= DATEADD(DAY,-21,GETUTCDATE())
    GROUP BY CAST(t.datephysical AS DATE)
),
daily_ctn AS (
    SELECT CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS d,
        SUM(jtr.qty) AS ctn_net_units
    FROM dbo.InventJournalTable jt
    INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
        AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
    WHERE jt.journalnameid='CTN-TRANSFER' AND jt.IsDelete IS NULL
      AND jt.createddatetime >= DATEADD(DAY,-21,GETUTCDATE())
    GROUP BY CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
),
daily_alloc AS (
    SELECT CAST(SinkCreatedOn AS DATE) AS d, SUM(allocatedquantity) AS alloc_units
    FROM dbo.pacAllocationDataLine
    WHERE SinkCreatedOn >= DATEADD(DAY,-21,GETUTCDATE())
    GROUP BY CAST(SinkCreatedOn AS DATE)
)
SELECT COALESCE(j.d, r.d, c.d, a.d) AS day_pst,
    j.journal_net_units,
    a.alloc_units       AS allocated_units,
    r.receipt_units,
    c.ctn_net_units
FROM nightly_journal j
FULL OUTER JOIN daily_receipts r ON r.d = j.d
FULL OUTER JOIN daily_ctn c ON c.d = COALESCE(j.d, r.d)
FULL OUTER JOIN daily_alloc a ON a.d = COALESCE(j.d, r.d, c.d)
ORDER BY day_pst;


-- ============================================================================
-- Q10. ALLOCATION-WAVE CORRELATION + THE 6/26 SELF-REVERSAL (decisive proof)
-- For every journal night in June: journal net vs same-day allocation and
-- receipt volume. Expected (all 13 June journal nights; 17 nights have no
-- journals at all due to creation gaps and are unmeasured):
--   6/7:  -83,418 <- CATCH-UP batch (10 journals) after the 6/1-6/6 creation
--         outage: multiple stale snapshot files compared vs live D365. Same
--         artifact family, triggered by staleness instead of flow surge.
--   6/10: -13,471 (normal); 6/18: -30,043 <- first run after 7-day journal
--         gap, catch-up flavor, elevated; 6/21: -10,778 (normal)
--   6/22-6/25: alloc 198-233K/day -> journal nets only -2K..-9K (steady state:
--              yesterday's staged wave invoices out as today's stages in)
--   6/26: alloc 256,846 -> journal net -144,083   <- Friday wave staged, spike
--   6/27: alloc  54,938 -> journal net   -8,668   <- SELF-REVERSED overnight:
--         no counting journal posted in between; the staged wave simply
--         shipped/invoiced through the weekend. Real shrink cannot do this.
--   6/29: alloc 171,958 -> journal net  -10,452   (weekend receipts aligned)
--   6/30: alloc 317,821 -> journal net -113,199   <- month-end monster wave
-- Among normal consecutive nightly runs, the only spikes are the two biggest
-- allocation days; every elevated June night has an artifact explanation.
-- Interpretation: the nightly journal net is a live gauge of the in-flight
-- population (staged outbound + received-not-putaway), breathing with the
-- allocation/receiving waves. It is not cumulative loss.
-- ============================================================================
WITH nightly_journal AS (
    SELECT CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS d,
        SUM(jtr.qty) AS journal_net
    FROM dbo.InventJournalTable jt
    INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
        AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
    WHERE jt.journalnameid='COU-DCSYNC' AND jt.IsDelete IS NULL
      AND jt.createddatetime >= '2026-06-01T00:00:00'
    GROUP BY CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
),
alloc AS (
    SELECT CAST(SinkCreatedOn AS DATE) AS d, SUM(allocatedquantity) AS alloc_units
    FROM dbo.pacAllocationDataLine
    WHERE SinkCreatedOn >= '2026-06-01'
    GROUP BY CAST(SinkCreatedOn AS DATE)
),
rcpts AS (
    SELECT CAST(t.datephysical AS DATE) AS d, SUM(t.qty) AS receipt_units
    FROM dbo.inventtransorigin o
    INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
    INNER JOIN dbo.inventdim dd ON dd.inventdimid = t.inventdimid AND dd.dataareaid='1001'
    WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
      AND dd.inventlocationid IN ('4901','4902','4905') AND o.referencecategory = 3
      AND t.datephysical >= '2026-06-01'
    GROUP BY CAST(t.datephysical AS DATE)
)
SELECT j.d AS journal_night, j.journal_net,
    a.alloc_units AS allocated_same_day,
    r.receipt_units AS received_same_day
FROM nightly_journal j
LEFT JOIN alloc a ON a.d = j.d
LEFT JOIN rcpts r ON r.d = j.d
ORDER BY j.d;


-- ============================================================================
-- Q11. COMPARISON-TIME SIMULATOR — models what a journal batch WOULD have
-- computed at a different comparison time, using the frozen journal values
-- plus CTN/MOV postings in the shift window. Used to evaluate the proposed
-- "move journal creation to ~4 AM PT" fix.
--
-- RESULT FOR 6/30 (documented 2026-07-01) — PROPOSAL REJECTED:
--   net:            -113,199 -> -104,022  (only 8% better)
--   gross artifact:  136,369 ->  146,716  (7.6% WORSE)
--   keys improved: 67   keys worsened: 511
--   new reverse (found-direction) artifacts: 303 keys / +6,510 units
--     (night-shift picks still in the snapshot but invoiced before 4 AM)
-- WHY: DC-dim CTN-TRANSFER invoices post in waves at ~4-5 PM PT (same evening,
-- BEFORE the current 10:36 PM journal) and ~12-1 PM PT the NEXT day; the
-- 11 PM-4 AM window itself moves only ~-9.7K units at DC dims. The month-end
-- staged freight took days to invoice — no comparison time captures it
-- without also eating the next day's receipts. Conclusion: timing change is
-- not the fix; use the ISS-01579 threshold guard + in-flight reconciliation.
--
-- To simulate other nights: change @journal_night and the window bounds
-- (@win_start/@win_end are UTC; keep the end before ~11:00 UTC / 4 AM PT so
-- receipts stay ~zero, otherwise the model must also include receipts).
-- ============================================================================
DECLARE @journal_night DATE = '2026-06-30';
DECLARE @win_start DATETIME2 = '2026-07-01T06:00:00';  -- 11:00 PM PT 6/30 (UTC)
DECLARE @win_end   DATETIME2 = '2026-07-01T11:00:00';  -- 4:00 AM PT 7/1  (UTC)

WITH frozen AS (
    SELECT jtr.itemid, jtr.inventdimid, SUM(jtr.qty) AS var_frozen
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    WHERE jt.journalnameid='COU-DCSYNC' AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)=@journal_night
    GROUP BY jtr.itemid, jtr.inventdimid
),
window_moves AS (
    SELECT jtr.itemid, jtr.inventdimid, SUM(jtr.qty) AS win_net
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001'
    WHERE jt.journalnameid IN ('CTN-TRANSFER','MOV-DCADJ') AND jt.posted=1
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4902','4905')
      AND jt.posteddatetime >= @win_start AND jt.posteddatetime < @win_end
    GROUP BY jtr.itemid, jtr.inventdimid
),
combined AS (
    SELECT COALESCE(f.itemid, w.itemid) AS itemid,
        COALESCE(f.inventdimid, w.inventdimid) AS dimid,
        ISNULL(f.var_frozen,0) AS var_frozen,
        ISNULL(f.var_frozen,0) - ISNULL(w.win_net,0) AS var_simulated
    FROM frozen f
    FULL OUTER JOIN window_moves w ON w.itemid = f.itemid AND w.inventdimid = f.inventdimid
),
item_wh AS (
    SELECT c.itemid, d.inventlocationid,
        SUM(c.var_frozen) AS frozen_net, SUM(c.var_simulated) AS sim_net
    FROM combined c
    INNER JOIN dbo.inventdim d ON d.inventdimid = c.dimid AND d.dataareaid='1001'
    GROUP BY c.itemid, d.inventlocationid
)
SELECT
    COUNT(*)                                                        AS item_wh_keys,
    SUM(frozen_net)                                                 AS total_frozen_net,
    SUM(sim_net)                                                    AS total_simulated_net,
    SUM(ABS(frozen_net))                                            AS abs_frozen,
    SUM(ABS(sim_net))                                               AS abs_simulated,
    SUM(CASE WHEN ABS(sim_net) < ABS(frozen_net) THEN 1 ELSE 0 END) AS keys_improved,
    SUM(CASE WHEN ABS(sim_net) > ABS(frozen_net) THEN 1 ELSE 0 END) AS keys_worsened,
    SUM(CASE WHEN frozen_net = 0 AND sim_net <> 0 THEN 1 ELSE 0 END) AS new_reverse_artifact_keys,
    SUM(CASE WHEN frozen_net = 0 THEN ABS(sim_net) ELSE 0 END)      AS reverse_artifact_units
FROM item_wh;


-- ============================================================================
-- Q12. DC-DIM CARTON-INVOICE POSTING RHYTHM — why no comparison time works
-- CTN-TRANSFER net units AT DC DIMENSIONS by posted hour. Expected (6/30-7/1):
--   6/30 16:00 PT: -13,288   6/30 17:00 PT: -21,335   <- same-evening waves,
--        already posted BEFORE the current 10:36 PM journal
--   7/1  03:00 PT:  -9,753   <- the entire overnight window moves this little
--   7/1  12:00 PT: -15,746   7/1 13:00 PT: -40,483    <- next-day midday waves
--        (to capture these you'd compare mid-afternoon — after ~100K+ of the
--        day's receipts have posted; strictly worse)
-- Note: large 00:00-03:00 "waves" appear in created-hour LINE counts, but most
-- of those lines are not at DC dims and barely affect the DC comparison.
-- ============================================================================
SELECT
    CAST(jt.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS day_pst,
    DATEPART(HOUR, jt.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS hour_pst,
    COUNT(DISTINCT jt.journalid) AS journals,
    SUM(jtr.qty) AS net_units_dc_dims,
    COUNT(*) AS lines
FROM dbo.InventJournalTable jt
INNER JOIN dbo.InventJournalTrans jtr ON jtr.journalid = jt.journalid
    AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001'
WHERE jt.journalnameid='CTN-TRANSFER' AND jt.posted=1 AND jt.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4902','4905')
  AND jt.posteddatetime >= '2026-06-30T20:00:00'
GROUP BY CAST(jt.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
    DATEPART(HOUR, jt.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time')
ORDER BY day_pst, hour_pst;


-- ============================================================================
-- Q13. MESSAGE-PROCESSING HEALTH — proves the lag is NOT in message processing
-- O3 carton-invoice files, message-level: arrival (createddatetime) vs
-- processed (statusdatetime), with status. MEASURED 6/29-7/2 (4,948 messages):
--   100% status 40 (processed); wait minutes p50=2, p95=25, p99=27, max=174
--   (one 2-message blip). WM creates invoices continuously (o3tcr stamps run
--   ~1:40 AM-11:59 PM ET); SFTP+parse lands them in minutes-to-~3h; message
--   processing clears them in ~2 minutes.
-- THEREFORE the 12-18h lag between physical shipment and D365 on-hand update
-- sits in ONE place: the batch that creates+posts CTN-TRANSFER (transit)
-- journals from carton transfer data — it runs in ~2 daily waves (~4-5 PM PT
-- and next-day ~noon PT, small 3 AM trickle; see Q12) instead of continuously.
-- That job/schedule (cf. paccartontransitjournalpostmultitracking, empty in
-- Synapse — check the D365 batch job directly) is the fix target.
-- ============================================================================
SELECT m.recid AS message_recid,
    m.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS arrived_pst,
    m.statusdatetime  AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS processed_pst,
    m.messagestatus,
    DATEDIFF(MINUTE, m.createddatetime, m.statusdatetime) AS wait_minutes,
    COUNT(h.recid) AS carton_headers
FROM dbo.sunintmessage m
INNER JOIN dbo.pacwminvoicecartonheadermessage h ON h.message = m.recid AND h.IsDelete IS NULL
WHERE m.IsDelete IS NULL
  AND m.createddatetime >= DATEADD(DAY,-3,GETUTCDATE())
GROUP BY m.recid, m.createddatetime, m.statusdatetime, m.messagestatus
ORDER BY m.createddatetime;


-- ============================================================================
-- Q14. CARTON LIFECYCLE vs THE INVENTORY MOVE — status flips are prompt, the
-- posting is not. Lifecycle: Created (0) -> In Transit (1/2) -> Received at
-- store (4). DC inventory is relieved at the created->in-transit POSTING;
-- store completion is not required (design rule). Note: header/line records
-- are created when EITHER the O3 or O4 file arrives (the pair can arrive out
-- of sequence), so status-0 rows without ship dates are often just waiting
-- for their counterpart file - not stuck.
-- MEASURED 2026-07-02: cartons reach status 1 within ~1h of row creation
-- (e.g. created 6:16 AM PT, In Transit by 7:14 AM), but the CTN-TRANSFER
-- journals that actually relieve 4901 post in ~2 daily waves (Q12) —
-- cartons can show In Transit for hours-to-a-day while D365 still carries
-- their stock at the DC. movementfeference is EMPTY in this flow (0 of
-- 5,794 recent cartons), so per-carton journal coupling must be checked in
-- D365 directly (open a status-1 carton; find its transit journal).
-- ============================================================================
-- 14a. Status distribution for recently created cartons
SELECT cartonstatus, COUNT(*) AS cartons,
    SUM(CASE WHEN shippeddatetime > '1990-01-01' THEN 1 ELSE 0 END) AS has_ship_dt,
    SUM(CASE WHEN ISNULL(movementfeference,'') <> '' THEN 1 ELSE 0 END) AS has_movement_ref
FROM dbo.paccartontransferheader
WHERE IsDelete IS NULL AND createddatetime >= DATEADD(DAY,-3,GETUTCDATE())
GROUP BY cartonstatus ORDER BY cartonstatus;

-- 14b. Sample recent in-transit cartons: row creation vs last status touch
SELECT TOP 20 h.cartonnumber, h.cartonstatus, h.fromwh, h.towh,
    h.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS row_created_pst,
    h.SinkModifiedOn  AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS last_modified_pst
FROM dbo.paccartontransferheader h
WHERE h.IsDelete IS NULL AND h.cartonstatus IN (1,2)
  AND h.createddatetime >= DATEADD(DAY,-2,GETUTCDATE())
ORDER BY h.createddatetime DESC;


-- ============================================================================
-- Q15. O3<->O4 PAIR-COMPLETION LAG + BATCH-JOB EXONERATION (correction to
-- the Q13/Q14 framing above). D365 batch history (user-verified 2026-07-02)
-- shows BOTH jobs — "Carton Move to In Transit" (5637370333) and "Carton
-- transfer journal posting-SVC" (5637749086) — run every 15 minutes, all
-- Ended, 3-30 second durations. The schedule is NOT the bottleneck.
-- Pair completion measured (O3s parsed 6/30-7/1, ~41K cartons):
--   <=15 min: 33,331 (81%; O4 arrived BEFORE O3 for 14,777 of these —
--             out-of-sequence arrival is routine and handled)
--   15-60 min: 5,809   1-4h: 1,490   >4h: 0   no O4 yet: 728 (1.7%)
-- YET journal creation stalls in multi-hour windows (7/1 04:00-11:00 PT:
-- zero CTN journals created anywhere) and then bursts. With schedule,
-- messages, and pairing all healthy, the gate is the WORK-SELECTION /
-- ELIGIBILITY logic inside the carton processing code (candidates: load/
-- trailer/pickticket-level completeness via o3ldno/o3mbol/o3pktn, transfer-
-- order readiness). Fix path: read the X++ selection criteria and trace one
-- carton whose O3+O4 both arrived by ~5 AM PT 7/1 but whose journal was not
-- created until ~12 PM PT.
-- ============================================================================
WITH o3 AS (
    SELECT o3casn AS casn, MIN(createddatetime) AS o3_arrived
    FROM dbo.pacwminvoicecartonheadermessage
    WHERE IsDelete IS NULL AND createddatetime >= DATEADD(DAY,-3,GETUTCDATE())
    GROUP BY o3casn
),
o4 AS (
    SELECT o4casn AS casn, MIN(createddatetime) AS o4_arrived
    FROM dbo.pacwminvoicecartonlinemessage
    WHERE IsDelete IS NULL AND createddatetime >= DATEADD(DAY,-4,GETUTCDATE())
    GROUP BY o4casn
)
SELECT
    CASE
        WHEN o4.casn IS NULL THEN 'X_no_O4_yet'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 15 THEN 'A_within_15min'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 60 THEN 'B_15-60min'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 240 THEN 'C_1-4h'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 720 THEN 'D_4-12h'
        ELSE 'E_over_12h'
    END AS o4_lag_bucket,
    COUNT(*) AS cartons,
    SUM(CASE WHEN o4.o4_arrived < o3.o3_arrived THEN 1 ELSE 0 END) AS o4_arrived_before_o3
FROM o3
LEFT JOIN o4 ON o4.casn = o3.casn
GROUP BY
    CASE
        WHEN o4.casn IS NULL THEN 'X_no_O4_yet'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 15 THEN 'A_within_15min'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 60 THEN 'B_15-60min'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 240 THEN 'C_1-4h'
        WHEN DATEDIFF(MINUTE, o3.o3_arrived, o4.o4_arrived) <= 720 THEN 'D_4-12h'
        ELSE 'E_over_12h'
    END
ORDER BY o4_lag_bucket;


-- ============================================================================
-- Q16. FINAL CORRECTION — STORE cartons vs PARCELS resolves everything.
-- O3 arrivals split by ship-to presence (store carton) vs absent (parcel):
--   STORE cartons arrive in ~2 daily batches (6/30: 13:00 PT 2,218 + 15:00 PT
--   814; 7/1: 03:00 PT 1,340 + 12:00 PT 1,304) — trailer-close cadence at WM.
--   PARCELS (e-comm, no ship-to) flow continuously all day — they never
--   produce CTN-TRANSFER journals (e-comm relief posts via sales orders).
-- DC journal creation follows each STORE batch within 0-3 hours (often the
-- same hour). CONCLUSION: the D365 pipeline is prompt end-to-end; the
-- twice-daily journal bursts mirror WM's store-carton invoice file cadence.
-- The phantom shrink is therefore the PHYSICAL pick-to-trailer-close latency
-- at WM (cartons leave counted buckets at pick; invoice cut at trailer
-- close), amplified at month-end when freight is staged days ahead. No
-- D365-side defect found. Mitigations: ISS-01579 threshold guard (primary);
-- surge-aware posting policy; optionally discuss with WM whether store-carton
-- invoices (or a staged-carton feed) can be sent closer to pick time.
-- ============================================================================
SELECT
    CAST(h.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS day_pst,
    DATEPART(HOUR, h.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS hr_pst,
    SUM(CASE WHEN ISNULL(h.o3shto,'') <> '' THEN 1 ELSE 0 END) AS store_cartons,
    SUM(CASE WHEN ISNULL(h.o3shto,'') = ''  THEN 1 ELSE 0 END) AS parcel_cartons
FROM dbo.pacwminvoicecartonheadermessage h
WHERE h.IsDelete IS NULL
  AND h.createddatetime >= DATEADD(DAY,-3,GETUTCDATE())
GROUP BY CAST(h.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
    DATEPART(HOUR, h.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time')
ORDER BY day_pst, hr_pst;
