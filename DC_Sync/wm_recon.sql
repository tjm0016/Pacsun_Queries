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
-- Key facts confirmed live on 2026-07-01 (not documented anywhere before this file):
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
--     pacwmdailysyncbucketmapping. Step 4c treats 606/03 (ASN receipt scan) as the
--     "goods receipt" event. Relabel if "GRS" means something more specific in WM terms.
--
-- Finding from the 2026-07-01 run (see chat/report for full detail): all 20 of the
-- SKU-level variances on that day trace back to a same-day PO receipt (most posted to
-- D365 within hours of the query running), while the WM comparison count comes from the
-- last nightly pxdcr snapshot - i.e. the gap is mostly TIMING_GAP, not real shrink, and
-- should self-correct at tonight's sync for all but the oldest-dated receipt in the set.
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
-- STEP 2: TOP 20 VARIANCES — current-state WM vs D365 gap (latest pxdcr snapshot
-- vs live INVENTSUM), net across Active + Lock_Code buckets per item/size/color.
-- Netting across buckets is what excludes LC_TO_ACTIVE_MOVEMENT: when a
-- lock-code release exactly offsets an active increase, net_gap = 0 and the
-- row is dropped automatically (WHERE net_gap <> 0).
-- ============================================================================
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr
    FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.inventlocationid, c.itemid, c.inventsizeid, c.inventcolorid,
           SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c
    CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr
      AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.inventlocationid, c.itemid, c.inventsizeid, c.inventcolorid
),
d365_net AS (
    SELECT sDim.inventlocationid, s.itemid, sDim.inventsizeid, sDim.inventcolorid,
           SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY sDim.inventlocationid, s.itemid, sDim.inventsizeid, sDim.inventcolorid
),
gap_by_sku AS (
    SELECT
        COALESCE(w.itemid, oh.itemid)               AS itemid,
        COALESCE(w.inventcolorid, oh.inventcolorid) AS inventcolorid,
        COALESCE(w.inventsizeid, oh.inventsizeid)   AS inventsizeid,
        SUM(ISNULL(w.wm_qty,0))                     AS wm_qty,
        SUM(ISNULL(oh.d365_qty,0))                  AS d365_qty,
        SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh
        ON  w.inventlocationid = oh.inventlocationid AND w.itemid = oh.itemid
        AND w.inventsizeid     = oh.inventsizeid     AND w.inventcolorid = oh.inventcolorid
    GROUP BY COALESCE(w.itemid, oh.itemid), COALESCE(w.inventcolorid, oh.inventcolorid),
             COALESCE(w.inventsizeid, oh.inventsizeid)
)
SELECT TOP 20 itemid, inventcolorid, inventsizeid, wm_qty, d365_qty, net_gap
FROM gap_by_sku
WHERE net_gap <> 0
ORDER BY ABS(net_gap) DESC;


-- ============================================================================
-- STEP 3a: TRANS-ACTION ROLLUP for the Top-20 items (last 14 days, DC locations)
-- Categories: ALLOCATION_SALES (referencecategory=0/SalesTable demand),
-- PO_RECEIPT (referencecategory=3/PurchTable), inventory movement journals
-- (MOV-DCADJ, CTN-TRANSFER). COU-DCSYNC itself is excluded — it's the
-- correction being investigated, not a contributing cause.
-- top20 is recomputed inline (same logic as Step 2) so this section is
-- self-contained and always reflects the current top-20, no manual paste needed.
-- ============================================================================
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
),
trans_rollup AS (
    SELECT
        t.itemid COLLATE DATABASE_DEFAULT AS itemid,
        CAST(CASE o.referencecategory
            WHEN 0 THEN 'ALLOCATION_SALES'
            WHEN 3 THEN 'PO_RECEIPT'
            ELSE CONCAT('OTHER_REFCAT_', o.referencecategory)
        END AS VARCHAR(60)) COLLATE DATABASE_DEFAULT AS category,
        COUNT(*)   AS trans_count,
        SUM(t.qty) AS net_qty
    FROM dbo.inventtransorigin o
    INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
    INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
    WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
      AND d.inventlocationid IN ('4901','4905')
      AND t.datephysical >= DATEADD(DAY,-14,GETUTCDATE())
      AND o.referencecategory IN (0,3)
      AND t.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
    GROUP BY t.itemid, o.referencecategory
    UNION ALL
    SELECT
        jtr.itemid COLLATE DATABASE_DEFAULT AS itemid,
        CAST(CONCAT('INVENTORY_MOVEMENT_', jt.journalnameid) AS VARCHAR(60)) COLLATE DATABASE_DEFAULT AS category,
        COUNT(*)     AS trans_count,
        SUM(jtr.qty) AS net_qty
    FROM dbo.InventJournalTrans jtr
    INNER JOIN dbo.InventJournalTable jt ON jt.journalid = jtr.journalid AND jt.IsDelete IS NULL
    INNER JOIN dbo.inventdim d ON d.inventdimid = jtr.inventdimid AND d.dataareaid='1001' AND d.IsDelete IS NULL
    WHERE jtr.dataareaid='1001' AND jtr.IsDelete IS NULL
      AND jt.journalnameid IN ('MOV-DCADJ','CTN-TRANSFER')
      AND d.inventlocationid IN ('4901','4905')
      AND jt.createddatetime >= DATEADD(DAY,-14,GETUTCDATE())
      AND jtr.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
    GROUP BY jtr.itemid, jt.journalnameid
)
SELECT * FROM trans_rollup ORDER BY itemid, category;


-- ============================================================================
-- STEP 3b / 4a: PIX ROLLUP + UNMAPPED PIX REPORT for the Top-20 items (14 days)
-- Aligns mapped PIX (via pacwmpixtransactionmappingtable, plus known-mapped
-- 606/03 ASN receipt, 620/pxaccd=03 allocation fulfillment, 615/01 product dims,
-- 605 daily sync) against everything else, which is reported as UNMAPPED.
-- itemid reconstructed as pxstyl-pxssfx-pxcolr (matches pacwmcounts.itemid format).
-- ============================================================================
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
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
-- Same top20 + pix_rollup logic as Step 3b, aggregated down to just the
-- UNMAPPED codes. These are transaction codes with no known posting path into
-- D365 that we can find in pacwmpixtransactionmappingtable or the other
-- known-mapped types (606/03, 620/pxaccd=03, 615/01, 605).
-- ============================================================================
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
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
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
)
SELECT
    e.itemid, e.colorid, e.sizeid,
    e.errordescription,
    COUNT(*)          AS error_count,
    SUM(e.asnqty)     AS total_error_qty,
    MIN(e.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS first_seen_pst,
    MAX(e.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time') AS last_seen_pst
FROM dbo.pacasnerrortable e
WHERE e.IsDelete IS NULL
  AND e.createddatetime >= DATEADD(DAY,-30,GETUTCDATE())
  AND e.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
GROUP BY e.itemid, e.colorid, e.sizeid, e.errordescription
ORDER BY total_error_qty DESC;


-- ============================================================================
-- STEP 4c: REPORT — Timing discrepancies: PIX receipt events (606/03 ASN scan)
-- vs PIX movement events (618 pick, 620/621 ship, 300 carton, 700 move) and
-- D365 PO receipt posting dates, for the Top-20 items.
-- NOTE: no literal PIX code named "GRS" was found in pacwmpixmessage or
-- pacwmdailysyncbucketmapping as of 2026-07-01 — this treats 606/03 (ASN
-- receipt scan) as the "goods receipt" event. Confirm/relabel if "GRS" refers
-- to something more specific in WM terminology.
-- ============================================================================
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
),
pix_events AS (
    SELECT
        (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT AS itemid,
        CAST(CASE
            WHEN p.pxtxtp='606' AND p.pxtxcd='03'                    THEN 'RECEIPT_SCAN'
            WHEN p.pxtxtp IN ('618','620','621','300','700')          THEN 'MOVEMENT'
            WHEN p.pxtxtp='605'                                       THEN 'DAILY_SYNC'
            ELSE 'OTHER'
        END AS VARCHAR(20)) COLLATE DATABASE_DEFAULT AS event_class,
        p.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS event_pst
    FROM dbo.pacwmpixmessage p
    WHERE p.IsDelete IS NULL
      AND p.createddatetime >= DATEADD(DAY,-14,GETUTCDATE())
      AND (p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
)
SELECT
    itemid, event_class,
    COUNT(*)       AS event_count,
    MIN(event_pst) AS first_event_pst,
    MAX(event_pst) AS last_event_pst
FROM pix_events
WHERE event_class IN ('RECEIPT_SCAN','MOVEMENT','DAILY_SYNC')
GROUP BY itemid, event_class
ORDER BY itemid, event_class;

-- D365-side PO receipt dates for the same items, to compare against the WM RECEIPT_SCAN
-- timestamps above — if the PO receipt date is "today", the gap is very likely
-- TIMING_GAP (tonight's WM sync will close it), not a real structural gap.
WITH latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901','4905')
),
wm_net AS (
    SELECT c.itemid, SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr AND c.inventlocationid IN ('4901','4905')
    GROUP BY c.itemid
),
d365_net AS (
    SELECT s.itemid, SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim ON sDim.inventdimid = s.inventdimid AND sDim.dataareaid='1001'
        AND sDim.IsDelete IS NULL AND sDim.inventlocationid IN ('4901','4905')
    WHERE s.dataareaid='1001' AND s.IsDelete IS NULL
    GROUP BY s.itemid
),
gap_by_item AS (
    SELECT COALESCE(w.itemid, oh.itemid) COLLATE DATABASE_DEFAULT AS itemid,
           SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh ON w.itemid = oh.itemid
    GROUP BY COALESCE(w.itemid, oh.itemid)
    HAVING SUM(ISNULL(w.wm_qty,0) - ISNULL(oh.d365_qty,0)) <> 0
),
top20 AS (
    SELECT TOP 20 itemid FROM gap_by_item ORDER BY ABS(net_gap) DESC
)
SELECT
    t.itemid COLLATE DATABASE_DEFAULT AS itemid,
    o.referenceid AS po_number,
    MIN(t.datephysical) AS first_receipt_date,
    MAX(t.datephysical) AS last_receipt_date,
    SUM(t.qty) AS total_received_qty
FROM dbo.inventtransorigin o
INNER JOIN dbo.inventtrans t ON t.inventtransorigin = o.recid AND t.dataareaid='1001'
INNER JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid='1001'
WHERE o.dataareaid='1001' AND o.IsDelete IS NULL AND t.IsDelete IS NULL
  AND d.inventlocationid IN ('4901','4905')
  AND o.referencecategory = 3
  AND t.itemid COLLATE DATABASE_DEFAULT IN (SELECT itemid FROM top20)
  AND t.datephysical >= DATEADD(DAY,-30,GETUTCDATE())
GROUP BY t.itemid, o.referenceid
ORDER BY t.itemid;
