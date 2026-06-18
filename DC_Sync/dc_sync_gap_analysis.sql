-- ============================================================
-- DC SYNC GAP ANALYSIS
-- Purpose : Identify gaps between WM daily count (PIX 605)
--           and D365 COU-DCSYNC counting journals
-- Server  : d365-synapse-ps-prod-ondemand.sql.azuresynapse.net
-- DB      : dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Locations: 4905 = Groveport DC, 4901 = Nedap DC
-- Notes   : - All dates converted to PST
--           - Ignore Lock_Code → Active movements (expected churn)
--           - pacdcreadytopost / pacthresholdcheck flags are 0
--             on all journals (posted and unposted); not a blocker
-- Related : ISS-01579 (threshold auto-post), ISS-01613 (606-02)
-- ============================================================


-- ============================================================
-- SECTION 1 : DAILY SYNC CALENDAR  (last 45 days)
-- For each sync date: journal count, posted vs unposted,
-- total lines, and a simple status label.
-- ============================================================

WITH journal_by_date AS (
    SELECT
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
            AS journal_date_pst,
        COUNT(*)                                                          AS journal_count,
        SUM(CASE WHEN posted = 1 THEN 1   ELSE 0 END)                    AS posted_count,
        SUM(CASE WHEN posted = 0 THEN 1   ELSE 0 END)                    AS unposted_count,
        SUM(numoflines)                                                   AS total_lines,
        SUM(CASE WHEN posted = 1 THEN numoflines ELSE 0 END)              AS posted_lines,
        SUM(CASE WHEN posted = 0 THEN numoflines ELSE 0 END)              AS unposted_lines,
        MAX(CASE WHEN posted = 1
                 THEN posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time'
                 END)                                                     AS last_posted_pst
    FROM dbo.InventJournalTable
    WHERE journalnameid = 'COU-DCSYNC'
      AND IsDelete        IS NULL
      AND createddatetime >= DATEADD(DAY, -45, GETUTCDATE())
    GROUP BY
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
),

wm_by_date AS (
    SELECT
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
            AS wm_date_pst,
        COUNT(*)                                                                        AS wm_line_count,
        COUNT(DISTINCT messageid)                                                       AS wm_message_count,
        SUM(CAST(wmcount AS DECIMAL(18,4)))                                             AS wm_total_qty,
        SUM(CASE WHEN wmslocationid = 'Active'    THEN CAST(wmcount AS DECIMAL(18,4)) ELSE 0 END)
            AS wm_active_qty,
        SUM(CASE WHEN wmslocationid = 'Lock_Code' THEN CAST(wmcount AS DECIMAL(18,4)) ELSE 0 END)
            AS wm_lockcode_qty,
        COUNT(DISTINCT CASE WHEN journal IS NULL OR journal = '' THEN recid END)        AS wm_unlinked_lines
    FROM dbo.pacwmcounts
    WHERE IsDelete        IS NULL
      AND createddatetime >= DATEADD(DAY, -45, GETUTCDATE())
    GROUP BY
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
)

SELECT
    COALESCE(j.journal_date_pst, w.wm_date_pst)  AS sync_date_pst,
    -- WM count side
    w.wm_line_count,
    w.wm_message_count,
    w.wm_active_qty,
    w.wm_lockcode_qty,
    w.wm_unlinked_lines,
    -- Journal side
    j.journal_count,
    j.posted_count,
    j.unposted_count,
    j.posted_lines,
    j.unposted_lines,
    j.last_posted_pst,
    -- Status label
    CASE
        WHEN w.wm_date_pst   IS NOT NULL AND j.journal_date_pst IS NULL THEN 'GAP - NO JOURNAL'
        WHEN j.journal_date_pst IS NOT NULL AND w.wm_date_pst   IS NULL THEN 'JOURNAL - NO WM DATA'
        WHEN j.unposted_count > 0 AND j.posted_count  = 0               THEN 'UNPOSTED - ALL'
        WHEN j.unposted_count > 0 AND j.posted_count  > 0               THEN 'UNPOSTED - PARTIAL'
        ELSE 'OK'
    END AS status
FROM journal_by_date j
FULL OUTER JOIN wm_by_date w ON j.journal_date_pst = w.wm_date_pst
ORDER BY sync_date_pst DESC;


-- ============================================================
-- SECTION 2 : UNPOSTED JOURNAL DETAIL
-- Lists every unposted COU-DCSYNC journal with age in days.
-- ============================================================

SELECT
    jt.journalid,
    jt.description,
    jt.numoflines,
    jt.pacdcreadytopost,
    jt.pacthresholdcheck,
    jt.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time'  AS created_pst,
    jt.posteddatetime,
    DATEDIFF(DAY, jt.createddatetime, GETUTCDATE())                             AS days_unposted,
    -- Count of WM lines linked to this journal
    (SELECT COUNT(*)
     FROM   dbo.pacwmcounts c
     WHERE  c.journal  = jt.journalid
       AND  c.IsDelete IS NULL)                                                  AS linked_wm_lines
FROM dbo.InventJournalTable jt
WHERE jt.journalnameid = 'COU-DCSYNC'
  AND jt.posted        = 0
  AND jt.IsDelete      IS NULL
ORDER BY jt.createddatetime DESC;


-- ============================================================
-- SECTION 3 : WM COUNT LINKAGE SUMMARY  (last 30 days)
-- For each date + DC location + WM bucket, shows how many
-- count lines are linked to a journal and if it was posted.
-- ============================================================

SELECT
    CAST(c.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
        AS sync_date_pst,
    c.inventlocationid,
    c.wmslocationid,
    COUNT(*)                                                                      AS wm_line_count,
    SUM(CAST(c.wmcount AS DECIMAL(18,4)))                                         AS wm_total_qty,
    SUM(CASE WHEN c.journal IS NULL OR c.journal = '' THEN 1 ELSE 0 END)          AS unlinked_lines,
    COUNT(DISTINCT c.journal)                                                     AS distinct_journals,
    MAX(CAST(jt.posted AS TINYINT))                                               AS any_journal_posted,
    SUM(CASE WHEN jt.posted = 0 THEN 1 ELSE 0 END)                               AS lines_on_unposted_journal
FROM dbo.pacwmcounts c
LEFT JOIN dbo.InventJournalTable jt
    ON  c.journal      = jt.journalid
    AND jt.IsDelete    IS NULL
WHERE c.IsDelete       IS NULL
  AND c.createddatetime >= DATEADD(DAY, -30, GETUTCDATE())
GROUP BY
    CAST(c.createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
    c.inventlocationid,
    c.wmslocationid
ORDER BY sync_date_pst DESC, c.inventlocationid, c.wmslocationid;


-- ============================================================
-- SECTION 4 : ITEM-LEVEL INVENTORY ADJUSTMENT GAPS
-- Shows items where D365 on-hand diverges from WM count,
-- ordered by magnitude of the pending adjustment.
--
-- HOW IT WORKS:
--   pacwmcounts has multiple raw PIX lines per item/size/color.
--   InventJournalTrans has ONE aggregated line per item/dim.
--   Pre-aggregating pacwmcounts avoids a counted fan-out where
--   SUM(t.counted) would multiply by the number of source rows.
--
--   counted = WM qty the journal was built from
--   qty     = counted - current D365 on-hand
--             negative = shrink (D365 will reduce on-hand)
--             positive = found inventory (D365 will increase)
--
-- Lock_Code to Active exclusion:
--   When net adjustment across both buckets = 0 for an item,
--   the lock_code reduction is fully offset by the active
--   increase; this is an expected release-from-hold, not a gap.
-- ============================================================

WITH wm_agg AS (
    SELECT
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)
            AS sync_date_pst,
        journal,
        itemid,
        inventsizeid,
        inventcolorid,
        wmslocationid,
        inventlocationid,
        SUM(CAST(wmcount AS DECIMAL(18,4)))  AS wm_qty
    FROM dbo.pacwmcounts
    WHERE IsDelete        IS NULL
      AND journal         IS NOT NULL
      AND journal         != ''
      AND inventlocationid = '4905'          -- Groveport; swap to '4901' for Nedap
      AND createddatetime >= DATEADD(DAY, -7, GETUTCDATE())
    GROUP BY
        CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE),
        journal, itemid, inventsizeid, inventcolorid, wmslocationid, inventlocationid
),

item_adj AS (
    SELECT
        w.sync_date_pst,
        w.inventlocationid,
        w.itemid,
        w.inventsizeid,
        w.inventcolorid,
        w.wmslocationid,
        w.wm_qty,
        t.counted                       AS d365_counted,
        t.qty                           AS d365_adj,
        w.journal,
        jt.posted                       AS journal_posted
    FROM wm_agg w
    JOIN dbo.InventJournalTrans t
        ON  w.journal      = t.journalid
        AND w.itemid       = t.itemid
        AND t.dataareaid   = '1001'
        AND t.IsDelete     IS NULL
    JOIN dbo.inventdim d
        ON  t.inventdimid       = d.inventdimid
        AND d.dataareaid        = '1001'
        AND d.IsDelete          IS NULL
        AND w.inventsizeid      = d.inventsizeid
        AND w.inventcolorid     = d.inventcolorid
        AND w.wmslocationid     = d.wmslocationid
        AND w.inventlocationid  = d.inventlocationid   -- prevents dimension fan-out
    JOIN dbo.InventJournalTable jt
        ON  w.journal      = jt.journalid
        AND jt.IsDelete    IS NULL
    WHERE t.qty <> 0
),

item_net AS (
    SELECT
        sync_date_pst,
        inventlocationid,
        itemid,
        inventsizeid,
        inventcolorid,
        SUM(d365_adj) AS net_adj
    FROM item_adj
    GROUP BY sync_date_pst, inventlocationid, itemid, inventsizeid, inventcolorid
)

SELECT
    a.sync_date_pst,
    a.inventlocationid,
    a.itemid,
    a.inventsizeid,
    a.inventcolorid,
    a.wmslocationid,
    a.wm_qty,
    a.d365_counted,
    a.d365_adj                          AS pending_adj_qty,
    n.net_adj                           AS item_net_adj,
    a.journal                           AS journal_id,
    a.journal_posted,
    CASE
        WHEN n.net_adj  = 0 THEN 'LC_TO_ACTIVE_MOVEMENT'
        WHEN a.d365_adj < 0 THEN 'SHRINK'
        WHEN a.d365_adj > 0 THEN 'FOUND_INVENTORY'
        ELSE 'OK'
    END AS gap_type
FROM item_adj a
JOIN item_net n
    ON  a.sync_date_pst    = n.sync_date_pst
    AND a.inventlocationid = n.inventlocationid
    AND a.itemid           = n.itemid
    AND a.inventsizeid     = n.inventsizeid
    AND a.inventcolorid    = n.inventcolorid
ORDER BY
    a.sync_date_pst    DESC,
    ABS(a.d365_adj)    DESC;


-- ============================================================
-- SECTION 5 : BACKLOG IMPACT SUMMARY
-- High-level counts to share with stakeholders.
-- ============================================================

SELECT
    SUM(CASE WHEN posted = 0 THEN 1 ELSE 0 END)                              AS unposted_journal_count,
    SUM(CASE WHEN posted = 0 THEN numoflines ELSE 0 END)                     AS unposted_line_count,
    MIN(CASE WHEN posted = 0
             THEN createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time'
             END)                                                             AS oldest_unposted_pst,
    MAX(CASE WHEN posted = 1
             THEN posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time'
             END)                                                             AS last_successful_post_pst,
    DATEDIFF(
        DAY,
        MAX(CASE WHEN posted = 1 THEN posteddatetime END),
        GETUTCDATE()
    )                                                                        AS days_since_last_post
FROM dbo.InventJournalTable
WHERE journalnameid = 'COU-DCSYNC'
  AND IsDelete      IS NULL;
