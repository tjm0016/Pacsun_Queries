-- =============================================================================
-- DC Leakage Matrix
-- SQL replacement for the intern's Python root_cause_leakage_matrix script.
--
-- Fixes vs original Python script:
--   1. Drops wmslocationid from the gap join key — the Python version compared
--      D365 Active vs WM Active and D365 Lock_Code vs WM Lock_Code separately,
--      creating phantom shrink because D365 posts negative on-hand at Lock_Code
--      when CTN-TRANSFER ships cartons (contra-account). Collapsing to net per
--      item+size+color gives the true gap.
--   2. Avoids fan-out on retailvariantid lookup by deduplicating through a CTE
--      rather than joining InventDim twice (which multiplies qty by # locations).
--   3. Separates TIMING_GAP (recent PO receipt in D365, WM ASN not yet processed)
--      from STRUCTURAL_GAP (D365 chronically overstated, no recent receipt to
--      explain it).
--   4. Pivots journal history into columns without Python/pandas.
--
-- Run against: Synapse Serverless (dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc)
-- Auth: AAD token via `az account get-access-token --resource https://database.windows.net`
-- =============================================================================

WITH

-- ── Latest WM snapshot ───────────────────────────────────────────────────────
latest_pxdcr AS (
    SELECT MAX(pxdcr) AS max_pxdcr,
           SUBSTRING(MAX(pxdcr), 3, 8) AS snap_date
    FROM dbo.pacwmcounts
    WHERE IsDelete IS NULL AND inventlocationid IN ('4901', '4905')
),

-- WM: net across ALL wmslocationids (Active + Lock_Code) per item+DC+size+color
wm_net AS (
    SELECT c.inventlocationid, c.itemid, c.inventsizeid, c.inventcolorid,
           SUM(CAST(c.wmcount AS DECIMAL(18,4))) AS wm_qty
    FROM dbo.pacwmcounts c
    CROSS JOIN latest_pxdcr lp
    WHERE c.IsDelete IS NULL AND c.pxdcr = lp.max_pxdcr
      AND c.inventlocationid IN ('4901', '4905')
    GROUP BY c.inventlocationid, c.itemid, c.inventsizeid, c.inventcolorid
),

-- D365: net across ALL wmslocationids per item+DC+size+color
d365_net AS (
    SELECT sDim.inventlocationid, s.itemid, sDim.inventsizeid, sDim.inventcolorid,
           SUM(s.physicalinvent) AS d365_qty
    FROM dbo.inventsum s
    JOIN dbo.inventdim sDim
        ON  sDim.inventdimid      = s.inventdimid
        AND sDim.dataareaid       = '1001'
        AND sDim.IsDelete         IS NULL
        AND sDim.inventlocationid IN ('4901', '4905')
    WHERE s.dataareaid = '1001' AND s.IsDelete IS NULL
    GROUP BY sDim.inventlocationid, s.itemid, sDim.inventsizeid, sDim.inventcolorid
),

-- Full outer join → gap per size-color row, then roll up to item level
gap_by_item AS (
    SELECT
        COALESCE(w.itemid, oh.itemid)             AS itemid,
        COALESCE(w.inventcolorid, oh.inventcolorid) AS inventcolorid,
        SUM(ISNULL(w.wm_qty, 0))                  AS wm_total,
        SUM(ISNULL(oh.d365_qty, 0))               AS d365_total,
        SUM(ISNULL(w.wm_qty, 0) - ISNULL(oh.d365_qty, 0)) AS net_gap
    FROM wm_net w
    FULL OUTER JOIN d365_net oh
        ON  w.inventlocationid = oh.inventlocationid
        AND w.itemid           = oh.itemid
        AND w.inventsizeid     = oh.inventsizeid
        AND w.inventcolorid    = oh.inventcolorid
    GROUP BY COALESCE(w.itemid, oh.itemid),
             COALESCE(w.inventcolorid, oh.inventcolorid)
    HAVING SUM(ISNULL(w.wm_qty, 0) - ISNULL(oh.d365_qty, 0)) < 0  -- shrink only
),

-- ── Retailvariantid lookup (fan-out-safe) ────────────────────────────────────
-- One retailvariantid per itemid+inventcolorid via inventdimcombination
retailvariant AS (
    SELECT DISTINCT dc.itemid, d.inventcolorid, dc.retailvariantid
    FROM dbo.inventdimcombination dc
    JOIN dbo.inventdim d
        ON  d.inventdimid  = dc.inventdimid
        AND d.dataareaid   = '1001'
        AND d.IsDelete     IS NULL
    WHERE dc.dataareaid = '1001' AND dc.IsDelete IS NULL
      AND dc.retailvariantid IS NOT NULL AND dc.retailvariantid <> ''
),

-- ── Timing gap flag ──────────────────────────────────────────────────────────
-- Items with a same-day or prior-day D365 PO receipt (blank voucher,
-- statusreceipt=2) that WM hasn't yet processed via ASN.
-- These gaps are self-correcting once WM receives the ASN tonight/tomorrow.
recent_receipts AS (
    SELECT DISTINCT it.itemid
    FROM dbo.inventtrans it
    JOIN dbo.inventdim d
        ON  d.inventdimid      = it.inventdimid
        AND d.dataareaid       = '1001'
        AND d.IsDelete         IS NULL
        AND d.inventlocationid IN ('4901', '4905')
    WHERE it.dataareaid     = '1001'
      AND it.IsDelete       IS NULL
      AND it.statusreceipt  = 2           -- Purchased (financially received)
      AND it.voucher        = ''          -- PO receipt posts with blank voucher before invoicing
      AND it.datephysical  >= DATEADD(DAY, -2, GETUTCDATE())
),

-- ── Journal activity last 14 days (posted only) ──────────────────────────────
-- Pivoted by journal type so each row shows what D365 has actually recorded.
-- Note: CTN-ALLOC is excluded — it's a forward allocation commitment, not an
--       inventory movement (units may not even be at DC yet when created).
journal_pivot AS (
    SELECT t.itemid,
           SUM(CASE WHEN j.journalnameid = 'CTN-TRANSFER' THEN t.qty ELSE 0 END) AS ctn_transfer_qty,
           SUM(CASE WHEN j.journalnameid = 'MOV-DCADJ'    THEN t.qty ELSE 0 END) AS mov_dcadj_qty,
           SUM(CASE WHEN j.journalnameid = 'COU-DCSYNC'   THEN t.qty ELSE 0 END) AS cou_dcsync_qty,
           SUM(CASE WHEN j.journalnameid = 'MOV-RFID'     THEN t.qty ELSE 0 END) AS mov_rfid_qty,
           SUM(CASE WHEN j.journalnameid = 'COU-INVSNAP'  THEN t.qty ELSE 0 END) AS cou_invsnap_qty,
           SUM(t.qty)                                                              AS total_posted_qty
    FROM dbo.InventJournalTrans t
    JOIN dbo.InventJournalTable j
        ON  j.journalid  = t.journalid
        AND j.IsDelete   IS NULL
        AND j.posted     = 1
        AND j.journalnameid IN ('CTN-TRANSFER','MOV-DCADJ','COU-DCSYNC','MOV-RFID','COU-INVSNAP')
    JOIN dbo.inventdim d
        ON  d.inventdimid      = t.inventdimid
        AND d.dataareaid       = '1001'
        AND d.IsDelete         IS NULL
        AND d.inventlocationid IN ('4901', '4905')
    WHERE t.IsDelete    IS NULL
      AND t.dataareaid  = '1001'
      AND j.createddatetime >= DATEADD(DAY, -14, GETUTCDATE())
    GROUP BY t.itemid
),

-- ── Unposted COU-DCSYNC proposed adjustments ─────────────────────────────────
-- What the backlogged journals WOULD post if the threshold check passed.
unposted_dcsync AS (
    SELECT t.itemid,
           SUM(t.qty)                                          AS proposed_net,
           SUM(CASE WHEN t.qty < 0 THEN t.qty ELSE 0 END)     AS proposed_shrink,
           SUM(CASE WHEN t.qty > 0 THEN t.qty ELSE 0 END)     AS proposed_found,
           COUNT(DISTINCT j.journalid)                         AS unposted_journal_count
    FROM dbo.InventJournalTrans t
    JOIN dbo.InventJournalTable j
        ON  j.journalid     = t.journalid
        AND j.IsDelete      IS NULL
        AND j.posted        = 0
        AND j.journalnameid = 'COU-DCSYNC'
    JOIN dbo.inventdim d
        ON  d.inventdimid      = t.inventdimid
        AND d.dataareaid       = '1001'
        AND d.IsDelete         IS NULL
        AND d.inventlocationid IN ('4901', '4905')
    WHERE t.IsDelete IS NULL AND t.dataareaid = '1001'
    GROUP BY t.itemid
)

-- ── Final output ──────────────────────────────────────────────────────────────
SELECT
    g.itemid,
    rv.retailvariantid,
    -- Gap: negative = D365 overstated vs WM (shrink). Positive = WM > D365 (found).
    g.wm_total                    AS wm_qty,
    g.d365_total                  AS d365_qty,
    g.net_gap                     AS gap_units,
    -- Classification: is this gap real or a timing artifact from a fresh PO receipt?
    CASE
        WHEN rr.itemid IS NOT NULL THEN 'TIMING_GAP'   -- PO received in D365 today, WM ASN pending
        ELSE 'STRUCTURAL_GAP'                           -- gap exists independent of recent receipt
    END AS gap_classification,
    -- Posted journal reductions in last 14 days (all negative = reducing D365 on-hand)
    ISNULL(jp.ctn_transfer_qty, 0) AS ctn_transfer_posted,
    ISNULL(jp.mov_dcadj_qty,    0) AS mov_dcadj_posted,
    ISNULL(jp.cou_dcsync_qty,   0) AS cou_dcsync_posted,
    ISNULL(jp.mov_rfid_qty,     0) AS mov_rfid_posted,
    ISNULL(jp.cou_invsnap_qty,  0) AS cou_invsnap_posted,
    -- Unposted COU-DCSYNC backlog (stuck due to threshold check / ISS-01579)
    ISNULL(ud.proposed_net,           0) AS dcsync_proposed_net,
    ISNULL(ud.proposed_shrink,        0) AS dcsync_proposed_shrink,
    ISNULL(ud.proposed_found,         0) AS dcsync_proposed_found,
    ISNULL(ud.unposted_journal_count, 0) AS dcsync_unposted_journals,
    -- Residual gap not explained by posted journals OR pending COU-DCSYNC correction
    g.net_gap
        - ISNULL(jp.ctn_transfer_qty, 0)
        - ISNULL(jp.mov_dcadj_qty,    0)
        - ISNULL(jp.cou_dcsync_qty,   0)
        - ISNULL(ud.proposed_net,     0)  AS residual_unexplained_gap
FROM gap_by_item g
LEFT JOIN retailvariant  rv ON rv.itemid = g.itemid AND rv.inventcolorid = g.inventcolorid
LEFT JOIN journal_pivot  jp ON jp.itemid = g.itemid
LEFT JOIN unposted_dcsync ud ON ud.itemid = g.itemid
LEFT JOIN recent_receipts rr ON rr.itemid = g.itemid
ORDER BY g.net_gap ASC;
