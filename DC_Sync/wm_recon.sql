-- ============================================================================
-- WM RECON
-- Methodology: Counting Journals -> Top Variances -> Trans/PIX Rollup -> Reports
-- Locations : 4905 = Groveport DC, 4901 = Nedap DC
-- Run against: Synapse Serverless (dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc)
-- Auth: AAD token via `az account get-access-token --resource https://database.windows.net`
--
-- Builds on prior work in this repo:
--   - dc_sync_gap_analysis.sql   (Section 1/6 - counting journal calendar, current-state gap)
--   - dc_leakage_matrix.sql      (net-across-buckets gap calc, journal pivot, TIMING_GAP concept)
--   - dc_shrink_root_cause.sql   (PIX transaction decode: 618/621/606/620/500)
--   - dbo.pacwmpixtransactionmappingtable (AUTHORITATIVE pxtxtp+pxtxcd+pxaccd -> MOV-DCADJ
--     mapping used by the integration itself - confirmed via direct query 2026-07-01)
--   - dbo.pacasnerrortable       (ASN receiving errors, not previously queried in this repo)
--
-- Key facts confirmed live on 2026-07-01:
--   - InventTransOrigin.referencecategory: 0=Sales(SO)/Allocation demand, 3=Purch(PO
--     receipts), 4=MOV-DCADJ, 6=CTN-TRANSFER, 13=COU-DCSYNC. Confirmed by joining
--     referenceid to SalesTable/PurchTable/InventJournalTable.
--   - Synapse serverless does not support VALUES table-value-constructors in a CTE
--     ("top20(itemid) AS (VALUES ...)") - use UNION ALL SELECT instead.
--   - Columns from different source tables carry different collations
--     (Latin1_General_100_CI_AS_SC_UTF8 vs ...BIN2_UTF8). Any UNION ALL or IN-subquery
--     mixing inventtrans/InventJournalTrans/pacwmpixmessage/literals needs an explicit
--     COLLATE DATABASE_DEFAULT on every itemid/text column involved or it throws
--     "Cannot resolve the collation conflict".
--   - No literal PIX code named "GRS" exists in pacwmpixmessage or
--     pacwmdailysyncbucketmapping.
--
-- CORRECTED METHODOLOGY (2026-07-01, second pass): the first version of Step 2 compared
-- the latest WM pacwmcounts snapshot against LIVE dbo.inventsum at query-run time. That's
-- an invalid cross-time comparison whenever a PO receipt posts between the WM snapshot and
-- your query - it manufactures fake "shrink" out of nothing. InventJournalTrans.qty for a
-- COU-DCSYNC journal is computed ONCE and FROZEN at journal-creation time (WM counted minus
-- D365 on-hand as of that moment) - read that instead of recomputing live. Step 2 below
-- uses the frozen qty from the most recent journal batch. See feedback memory
-- "journal-vs-live-comparison" for the full story of how this was caught.
--
-- Finding from the corrected run: nearly all of the top-20 items sit near-zero net qty
-- through 6/29, then jump sharply and simultaneously on the night of 6/30 - not one item's
-- fluke, a shared pattern. Step 3a explains the shape: each item got one large PO_RECEIPT
-- sometime 6/25-6/30, and CTN-TRANSFER has posted large negative quantities EVERY DAY SINCE
-- at high volume. This is a cumulative multi-day pattern, not a same-day timing blip.
-- Leading candidate mechanism: PIX 618/55/03 (pick-short/inventory-variance) is the largest
-- unmapped-PIX signal, hitting all 20 items (~157K units/14 days) - a plausible direct
-- explanation for why WM's physical count runs behind D365's book qty on exactly the
-- highest-volume shipping items. Not confirmed as root cause; CTN-TRANSFER posting-vs-
-- physical-count lag is an equally live alternative. Needs WM ops input to resolve further.
-- ============================================================================


-- ============================================================================
-- STEP 1: COUNTING JOURNALS — daily posting calendar (last 30 days)
-- ============================================================================
SELECT
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS journal_date_pst,
    COUNT(*)                                       AS journal_count,
    SUM(CASE WHEN jt.posted=1 THEN 1 ELSE 0 END)   AS posted_count,
    SUM(CASE WHEN jt.posted=0 THEN 1 ELSE 0 END)   AS unposted_count,
    SUM(jt.numoflines)                             AS total_lines
FROM dbo.InventJournalTable jt
WHERE jt.journalnameid = 'COU-DCSYNC' AND jt.IsDelete IS NULL
  AND jt.createddatetime >= DATEADD(DAY,-30,GETUTCDATE())
GROUP BY CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
ORDER BY journal_date_pst DESC;


-- ============================================================================
-- STEP 2: TOP 20 VARIANCES — frozen InventJournalTrans.qty from the most recent
-- COU-DCSYNC journal batch, summed per item across ALL lines/buckets in that batch.
-- Summing across buckets is what excludes LC_TO_ACTIVE_MOVEMENT (a lock-code release
-- that exactly offsets an active increase nets to ~0 and won't rank near the top).
-- net_to_gross_ratio close to 1 = one-directional, real signal; close to 0 = mostly a
-- wash between buckets (WM has the units, just in a different bucket than D365 expects).
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
           SUM(jtr.qty)        AS net_qty,
           SUM(ABS(jtr.qty))   AS gross_qty,
           COUNT(*)            AS line_count
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
)
SELECT TOP 20
    itemid, net_qty, gross_qty, line_count,
    CASE WHEN gross_qty > 0 THEN CAST(ABS(net_qty) AS DECIMAL(18,4)) / gross_qty ELSE NULL END AS net_to_gross_ratio
FROM item_net
ORDER BY ABS(net_qty) DESC;


-- ============================================================================
-- STEP 2b: MULTI-NIGHT TREND for the Top-20 items, last ~7 nights of COU-DCSYNC
-- journals (posted + unposted). Reveals whether an item's imbalance is new (only
-- appears on the latest night), a recurring wash (large gross, near-zero net, every
-- night), or a persistent/growing real gap (net stays large across multiple nights).
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
)
SELECT
    jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS night_pst,
    MAX(jt.posted)      AS any_posted,
    SUM(jtr.qty)         AS net_qty,
    SUM(ABS(jtr.qty))    AS gross_qty,
    COUNT(*)             AS line_count
FROM dbo.InventJournalTrans jtr
INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
WHERE jt.journalnameid = 'COU-DCSYNC'
  AND jt.createddatetime >= DATEADD(DAY,-7,GETUTCDATE())
  AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4905')
  AND jtr.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
GROUP BY jtr.itemid, CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
ORDER BY itemid, night_pst;


-- ============================================================================
-- STEP 3a: TRANS-ACTION ROLLUP, dated, for the Top-20 items (since 6/25, DC locations)
-- Categories: ALLOCATION_SALES (referencecategory=0/SalesTable demand), PO_RECEIPT
-- (referencecategory=3/PurchTable), inventory movement journals (MOV-DCADJ,
-- CTN-TRANSFER). Dated by day so you can see the receipt-then-drawdown pattern.
-- COU-DCSYNC itself is excluded — it's the correction being investigated.
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
)
SELECT
    t.itemid COLLATE DATABASE_DEFAULT AS itemid,
    CAST(CASE o.referencecategory
        WHEN 0 THEN 'ALLOCATION_SALES'
        WHEN 3 THEN 'PO_RECEIPT'
        ELSE CONCAT('OTHER_REFCAT_', o.referencecategory)
    END AS VARCHAR(60)) COLLATE DATABASE_DEFAULT AS category,
    CAST(t.datephysical AS DATE) AS trans_date,
    COUNT(*)   AS trans_count,
    SUM(t.qty) AS net_qty
FROM dbo.inventtransorigin o
INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4905')
  AND t.datephysical >= '2026-06-25'
  AND o.referencecategory IN (0,3)
  AND t.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
GROUP BY t.itemid, o.referencecategory, CAST(t.datephysical AS DATE)
UNION ALL
SELECT
    jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
    CAST(CONCAT('INVENTORY_MOVEMENT_', jt.journalnameid) AS VARCHAR(60)) COLLATE DATABASE_DEFAULT AS category,
    CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) AS trans_date,
    COUNT(*)     AS trans_count,
    SUM(jtr.qty) AS net_qty
FROM dbo.InventJournalTrans jtr
INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
WHERE jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
  AND jt.journalnameid IN ('MOV-DCADJ','CTN-TRANSFER')
  AND d.inventlocationid IN ('4901','4905')
  AND jt.createddatetime >= '2026-06-25'
  AND jtr.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
GROUP BY jtr.itemid, jt.journalnameid, CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
ORDER BY itemid, trans_date;


-- ============================================================================
-- STEP 3b / 4a: PIX ROLLUP + UNMAPPED PIX REPORT for the Top-20 items (14 days)
-- Aligns mapped PIX (via pacwmpixtransactionmappingtable, plus known-mapped 606/03
-- ASN receipt, 620/pxaccd=03 allocation fulfillment, 615/01 product dims, 605 daily
-- sync) against everything else, which is reported as UNMAPPED.
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
),
pix_rollup AS (
    SELECT
        (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT AS itemid,
        p.pxtxtp, p.pxtxcd, p.pxaccd,
        CAST(m.journalnameid AS VARCHAR(30)) COLLATE DATABASE_DEFAULT AS mapped_journal,
        CAST(CASE
            WHEN m.journalnameid IS NOT NULL          THEN 'MAPPED'
            WHEN p.pxtxtp='606' AND p.pxtxcd='03'     THEN 'MAPPED'
            WHEN p.pxtxtp='620' AND p.pxaccd='03'     THEN 'MAPPED'
            WHEN p.pxtxtp='615' AND p.pxtxcd='01'     THEN 'MAPPED'
            WHEN p.pxtxtp='605'                        THEN 'MAPPED'
            ELSE 'UNMAPPED'
        END AS VARCHAR(20)) COLLATE DATABASE_DEFAULT AS mapping_status,
        COUNT(*)                                  AS tx_count,
        SUM(CAST(p.pxinva AS BIGINT)) / 10000.0   AS pix_qty
    FROM dbo.pacwmpixmessage p
    OUTER APPLY (
        SELECT TOP 1 mm.journalnameid
        FROM dbo.pacwmpixtransactionmappingtable mm
        WHERE mm.pxtxtp = p.pxtxtp AND mm.pxtxcd = p.pxtxcd
          AND (mm.pxaccd = p.pxaccd OR mm.pxaccd = '' OR mm.pxaccd IS NULL)
        ORDER BY CASE WHEN mm.pxaccd = p.pxaccd THEN 0 ELSE 1 END
    ) m
    WHERE p.IsDelete IS NULL
      AND p.createddatetime >= DATEADD(DAY,-14,GETUTCDATE())
      AND (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
    GROUP BY p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr, p.pxtxtp, p.pxtxcd, p.pxaccd, m.journalnameid
)
-- Full mapped+unmapped detail (Step 3b):
SELECT * FROM pix_rollup ORDER BY itemid, mapping_status, pix_qty DESC;


-- ============================================================================
-- STEP 4a: REPORT — Unmapped PIX qty, by PIX code (across Top-20 items, 14 days)
-- Same top20 + pix_rollup logic as Step 3b, aggregated down to just the UNMAPPED
-- codes. As of 2026-07-01: 618/55/03 (pick-short/inventory-variance) is the largest,
-- hitting all 20 items — the leading candidate mechanism for the gap. 906/02 is
-- second-largest and still completely undocumented; ask WM/Nedap what it represents.
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
),
pix_rollup AS (
    SELECT
        (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT AS itemid,
        p.pxtxtp, p.pxtxcd, p.pxaccd,
        CAST(CASE
            WHEN m.journalnameid IS NOT NULL          THEN 'MAPPED'
            WHEN p.pxtxtp='606' AND p.pxtxcd='03'     THEN 'MAPPED'
            WHEN p.pxtxtp='620' AND p.pxaccd='03'     THEN 'MAPPED'
            WHEN p.pxtxtp='615' AND p.pxtxcd='01'     THEN 'MAPPED'
            WHEN p.pxtxtp='605'                        THEN 'MAPPED'
            ELSE 'UNMAPPED'
        END AS VARCHAR(20)) COLLATE DATABASE_DEFAULT AS mapping_status,
        CAST(p.pxinva AS BIGINT) / 10000.0 AS pix_qty
    FROM dbo.pacwmpixmessage p
    OUTER APPLY (
        SELECT TOP 1 mm.journalnameid
        FROM dbo.pacwmpixtransactionmappingtable mm
        WHERE mm.pxtxtp = p.pxtxtp AND mm.pxtxcd = p.pxtxcd
          AND (mm.pxaccd = p.pxaccd OR mm.pxaccd = '' OR mm.pxaccd IS NULL)
        ORDER BY CASE WHEN mm.pxaccd = p.pxaccd THEN 0 ELSE 1 END
    ) m
    WHERE p.IsDelete IS NULL
      AND p.createddatetime >= DATEADD(DAY,-14,GETUTCDATE())
      AND (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
)
SELECT pxtxtp, pxtxcd, pxaccd,
    COUNT(*) AS tx_count, SUM(pix_qty) AS total_qty, COUNT(DISTINCT itemid) AS item_count
FROM pix_rollup
WHERE mapping_status = 'UNMAPPED'
GROUP BY pxtxtp, pxtxcd, pxaccd
ORDER BY total_qty DESC;


-- ============================================================================
-- STEP 4b: REPORT — ASN error qty for the Top-20 items (last 30 days)
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
)
SELECT
    e.itemid, e.colorid, e.sizeid, e.errordescription,
    COUNT(*)          AS error_count,
    SUM(e.asnqty)     AS total_error_qty,
    MIN(e.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS first_seen_pst
FROM dbo.pacasnerrortable e
WHERE e.IsDelete IS NULL
  AND e.createddatetime >= DATEADD(DAY,-30,GETUTCDATE())
  AND e.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
GROUP BY e.itemid, e.colorid, e.sizeid, e.errordescription
ORDER BY total_error_qty DESC;


-- ============================================================================
-- STEP 4c: REPORT — Timing discrepancy: days since each item's most recent PO
-- receipt vs. cumulative CTN-TRANSFER volume posted since that receipt. This is
-- the corrected replacement for an earlier version of this report that compared
-- PIX event timestamps directly and concluded (wrongly) that all 20 items were a
-- same-day artifact — see the file header notes above. A large
-- ctn_transfer_qty_since_receipt relative to qty_on_last_receipt_date, accumulating
-- over several days, is the actual pattern found on 2026-07-01.
-- ============================================================================
WITH latest_journal_batch AS (
    SELECT MAX(CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)) AS latest_night
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC' AND IsDelete IS NULL
),
item_net AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    CROSS JOIN latest_journal_batch lb
    WHERE jt.journalnameid = 'COU-DCSYNC'
      AND CAST(jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = lb.latest_night
      AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
    GROUP BY jtr.itemid
),
top20 AS (
    SELECT TOP 20 itemid FROM item_net ORDER BY ABS(net_qty) DESC
),
last_receipt AS (
    SELECT t.itemid COLLATE DATABASE_DEFAULT AS itemid, MAX(t.datephysical) AS last_receipt_date
    FROM dbo.inventtransorigin o
    INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
    INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
    WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905') AND o.referencecategory = 3
      AND t.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
    GROUP BY t.itemid
),
receipt_qty AS (
    SELECT t.itemid COLLATE DATABASE_DEFAULT AS itemid, SUM(t.qty) AS qty_on_last_receipt_date
    FROM dbo.inventtransorigin o
    INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
    INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
    INNER JOIN last_receipt lr ON lr.itemid = t.itemid COLLATE DATABASE_DEFAULT AND t.datephysical = lr.last_receipt_date
    WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905') AND o.referencecategory = 3
    GROUP BY t.itemid
),
ctn_since_receipt AS (
    SELECT jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
           SUM(jtr.qty) AS ctn_transfer_qty_since_receipt,
           COUNT(*) AS line_count
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    INNER JOIN last_receipt lr ON lr.itemid = jtr.itemid COLLATE DATABASE_DEFAULT
    WHERE jt.journalnameid = 'CTN-TRANSFER' AND jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
      AND jt.createddatetime >= CAST(lr.last_receipt_date AS DATETIME2)
    GROUP BY jtr.itemid
)
SELECT
    lr.itemid,
    lr.last_receipt_date,
    rq.qty_on_last_receipt_date,
    DATEDIFF(DAY, lr.last_receipt_date, GETUTCDATE())        AS days_since_receipt,
    ISNULL(cs.ctn_transfer_qty_since_receipt, 0)             AS ctn_transfer_qty_since_receipt,
    ISNULL(cs.line_count, 0)                                 AS ctn_transfer_lines_since_receipt
FROM last_receipt lr
LEFT JOIN receipt_qty rq ON rq.itemid = lr.itemid
LEFT JOIN ctn_since_receipt cs ON cs.itemid = lr.itemid
ORDER BY days_since_receipt;
