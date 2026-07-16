-- =============================================================================
-- DC 24-Hour Shrink Root Cause Analysis
-- Compares two consecutive WM daily sync snapshots (pxdcr) and cross-references
-- non-605 PIX messages to classify WHY WM Active count dropped between runs.
--
-- PIX Transaction Key:
--   618/10  = Confirmed pick from Active shelf (unmapped)
--   621/002 = Final carton ship confirmation (unmapped)
--   500/01  = Pack operation (unmapped)
--   618/55 + rscd=IV = Pick short / inventory variance (unmapped)
--   606/03  = ASN inbound receipt (MAPPED)
--   620/03  = Allocation fulfillment outbound (MAPPED)
--
-- Run against: Synapse Serverless (dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc)
-- Auth: AAD token via `az account get-access-token --resource https://database.windows.net`
-- =============================================================================

-- *** PARAMETERS: change these two pxdcr values to compare any two days ***
-- pxdcr format: 'DDYYYYMMDD'  (DD=02 for Groveport)
DECLARE @today_pxdcr VARCHAR(12) = '020260617';   -- more recent snapshot
DECLARE @yest_pxdcr  VARCHAR(12) = '020260616';   -- prior snapshot

-- =============================================================================
-- SECTION 1: Item-level shrink classification (summary view — start here)
-- =============================================================================
WITH
today_cnts AS (
    SELECT itemid, inventsizeid, inventcolorid, wmslocationid,
           SUM(CAST(wmcount AS DECIMAL(18,4))) AS qty
    FROM dbo.pacwmcounts
    WHERE pxdcr = @today_pxdcr AND IsDelete IS NULL AND inventlocationid = '4905'
    GROUP BY itemid, inventsizeid, inventcolorid, wmslocationid
),
yest_cnts AS (
    SELECT itemid, inventsizeid, inventcolorid, wmslocationid,
           SUM(CAST(wmcount AS DECIMAL(18,4))) AS qty
    FROM dbo.pacwmcounts
    WHERE pxdcr = @yest_pxdcr AND IsDelete IS NULL AND inventlocationid = '4905'
    GROUP BY itemid, inventsizeid, inventcolorid, wmslocationid
),
delta AS (
    SELECT COALESCE(t.itemid, y.itemid)             AS itemid,
           COALESCE(t.inventsizeid, y.inventsizeid)  AS inventsizeid,
           COALESCE(t.inventcolorid, y.inventcolorid) AS inventcolorid,
           COALESCE(t.wmslocationid, y.wmslocationid) AS wmslocationid,
           ISNULL(t.qty, 0) AS today_qty,
           ISNULL(y.qty, 0) AS yest_qty,
           ISNULL(t.qty, 0) - ISNULL(y.qty, 0) AS delta_qty
    FROM today_cnts t
    FULL OUTER JOIN yest_cnts y
        ON  t.itemid        = y.itemid
        AND t.inventsizeid  = y.inventsizeid
        AND t.inventcolorid = y.inventcolorid
        AND t.wmslocationid = y.wmslocationid
),
-- Collapse sizes: one row per item with Active + LC deltas
item_delta AS (
    SELECT itemid, inventcolorid,
           SUM(CASE WHEN wmslocationid = 'Active'    THEN delta_qty ELSE 0 END) AS active_delta,
           SUM(CASE WHEN wmslocationid = 'Lock_Code' THEN delta_qty ELSE 0 END) AS lc_delta,
           SUM(delta_qty) AS net_delta
    FROM delta
    GROUP BY itemid, inventcolorid
    HAVING SUM(CASE WHEN wmslocationid = 'Active' THEN delta_qty ELSE 0 END) < -30
),
-- Pivot PIX non-605 messages for the more recent snapshot day
pix_cats AS (
    SELECT
        p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr AS itemid,
        -- 621/002 = last carton ship event — best single "units shipped" signal
        SUM(CASE WHEN p.pxtxtp='621' AND p.pxtxcd='002' AND p.pxinat='A'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS ship_621_002,
        -- 618/10 = confirmed pick from Active shelf (can be pallet-level bulk picks)
        SUM(CASE WHEN p.pxtxtp='618' AND p.pxtxcd='10'  AND p.pxinat='A'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS pick_618_10,
        -- 618/55 rscd=IV = pick short / item not found during pick (inventory variance)
        SUM(CASE WHEN p.pxtxtp='618' AND p.pxtxcd='55' AND p.pxrscd='IV'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS iv_618_55,
        -- 606/03 = ASN inbound receipt (ADDS to inventory — offset against outbound)
        SUM(CASE WHEN p.pxtxtp='606' AND p.pxtxcd='03'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS receipt_606,
        -- 620/03 = Allocation fulfillment (MAPPED — D365 already knows about this)
        SUM(CASE WHEN p.pxtxtp='620' AND p.pxaccd='03'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS alloc_620_mapped,
        -- 500/01 = pack (same units as 621 but earlier step — cross-reference only)
        SUM(CASE WHEN p.pxtxtp='500'  AND p.pxinat='A'
                 THEN CAST(p.pxinva AS BIGINT)/10000.0 ELSE 0 END) AS pack_500,
        MAX(CASE WHEN p.pxtxtp='620' AND p.pxaccd='03' THEN 1 ELSE 0 END) AS has_mapped_alloc,
        COUNT(DISTINCT p.pxtxtp) AS distinct_pix_types
    FROM dbo.pacwmpixmessage p
    WHERE p.IsDelete IS NULL AND p.pxdcr = @today_pxdcr AND p.pxtxtp != '605'
    GROUP BY p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr
)
SELECT
    id.itemid,
    id.active_delta,
    id.lc_delta,
    id.net_delta,
    -- Outbound signal columns
    ISNULL(pc.ship_621_002, 0) AS ship_qty_621,   -- carton shipments (best for standard replen)
    ISNULL(pc.pick_618_10, 0)  AS pick_qty_618,   -- picks (closer signal for bulk transfers)
    ISNULL(pc.iv_618_55, 0)    AS iv_variance_qty, -- pick shorts / item-not-found
    ISNULL(pc.receipt_606, 0)  AS receipt_qty,     -- inbound (adds inventory)
    ISNULL(pc.alloc_620_mapped,0) AS mapped_alloc_qty, -- D365-aware outbound
    ISNULL(pc.pack_500, 0)     AS pack_qty_500,
    pc.has_mapped_alloc,
    pc.distinct_pix_types,
    -- Shrink classification logic:
    -- Standard replenishment → 621/002 ≈ count delta
    -- Bulk transfer/DC move → 618/10 ≈ count delta, 621 ≈ 0
    -- Genuine unexplained → count delta >> all PIX outbound
    CASE
        WHEN pc.itemid IS NULL
             THEN 'NO_PIX_ACTIVITY'
        WHEN ISNULL(pc.ship_621_002,0) = 0 AND ISNULL(pc.iv_618_55,0) = 0
             AND ISNULL(pc.pick_618_10,0) < ABS(id.active_delta) * 0.25
             THEN 'GENUINE_UNEXPLAINED'   -- <25% of shrink covered by any pick signal
        WHEN ABS(id.active_delta + ISNULL(pc.ship_621_002,0)) < ABS(id.active_delta) * 0.15
             THEN 'EXPLAINED_CARTON_SHIP' -- 621 ship qty matches count drop (standard replen)
        WHEN ISNULL(pc.ship_621_002,0) < 10
             AND ABS(id.active_delta + ISNULL(pc.pick_618_10,0)) < ABS(id.active_delta) * 0.20
             THEN 'EXPLAINED_BULK_PICK'   -- 618 qty matches, 621 absent (pallet/DC transfer)
        WHEN (ISNULL(pc.ship_621_002,0) + ISNULL(pc.iv_618_55,0)) >
             ABS(id.active_delta) * 0.85
             THEN 'EXPLAINED_COMBINED'    -- ship + IV variance together cover the drop
        WHEN pc.has_mapped_alloc = 1
             THEN 'HAS_MAPPED_ALLOC'      -- D365 620 integration also fired; partial D365 coverage
        ELSE 'PARTIAL_PIX_COVERAGE'       -- some outbound PIX but doesn't fully explain delta
    END AS shrink_classification
FROM item_delta id
LEFT JOIN pix_cats pc ON id.itemid = pc.itemid
ORDER BY id.active_delta ASC;


-- =============================================================================
-- SECTION 2: Size-level detail for a specific item
-- Replace @item_filter to drill into any single item from Section 1
-- =============================================================================
/*
DECLARE @item_filter VARCHAR(20) = '0656-49139-0009';  -- swap in itemid from Section 1

WITH
sz_delta AS (
    SELECT
        COALESCE(t.inventsizeid, y.inventsizeid) AS inventsizeid,
        COALESCE(t.wmslocationid, y.wmslocationid) AS wmslocationid,
        ISNULL(t.qty, 0) AS today_qty,
        ISNULL(y.qty, 0) AS yest_qty,
        ISNULL(t.qty, 0) - ISNULL(y.qty, 0) AS delta_qty
    FROM (
        SELECT inventsizeid, wmslocationid, SUM(CAST(wmcount AS DECIMAL(18,4))) AS qty
        FROM dbo.pacwmcounts
        WHERE pxdcr=@today_pxdcr AND IsDelete IS NULL AND inventlocationid='4905'
          AND itemid=@item_filter
        GROUP BY inventsizeid, wmslocationid
    ) t
    FULL OUTER JOIN (
        SELECT inventsizeid, wmslocationid, SUM(CAST(wmcount AS DECIMAL(18,4))) AS qty
        FROM dbo.pacwmcounts
        WHERE pxdcr=@yest_pxdcr AND IsDelete IS NULL AND inventlocationid='4905'
          AND itemid=@item_filter
        GROUP BY inventsizeid, wmslocationid
    ) y ON t.inventsizeid=y.inventsizeid AND t.wmslocationid=y.wmslocationid
),
pix_detail AS (
    SELECT
        p.pxszcd AS inventsizeid,
        p.pxtxtp, p.pxtxcd, p.pxaccd, p.pxrscd, p.pxinat,
        COUNT(*) AS tx_count,
        SUM(CAST(p.pxinva AS BIGINT))/10000.0 AS pix_qty,
        CASE
            WHEN p.pxtxtp='606' AND p.pxtxcd='03'               THEN 'MAPPED - ASN Receipt'
            WHEN p.pxtxtp='620' AND p.pxaccd='03'               THEN 'MAPPED - Alloc Fulfillment'
            WHEN p.pxtxtp='615' AND p.pxtxcd='01'               THEN 'MAPPED - Product Dims'
            WHEN p.pxtxtp='617' AND p.pxtxcd='03' AND p.pxaccd='01' THEN 'MAPPED - Manual ASN'
            WHEN p.pxtxtp='302'                                   THEN 'MAPPED - Maintain Carton'
            WHEN p.pxtxtp='901' AND p.pxtxcd='01' AND p.pxaccd='19' THEN 'MAPPED - Sample History'
            WHEN p.pxtxtp='618' AND p.pxtxcd='10'               THEN 'UNMAPPED - Confirm Pick'
            WHEN p.pxtxtp='618' AND p.pxtxcd='25'               THEN 'UNMAPPED - Redistribute Pick'
            WHEN p.pxtxtp='618' AND p.pxtxcd='30'               THEN 'UNMAPPED - Cancel/Return Pick'
            WHEN p.pxtxtp='618' AND p.pxtxcd='55' AND p.pxrscd='IV' THEN 'UNMAPPED - Pick Short (IV)'
            WHEN p.pxtxtp='618'                                   THEN 'UNMAPPED - Pick Other'
            WHEN p.pxtxtp='621' AND p.pxtxcd='001'              THEN 'UNMAPPED - Ship Start'
            WHEN p.pxtxtp='621' AND p.pxtxcd='002'              THEN 'UNMAPPED - Ship Confirm'
            WHEN p.pxtxtp='621' AND p.pxtxcd='025'              THEN 'UNMAPPED - Ship Close'
            WHEN p.pxtxtp='621'                                   THEN 'UNMAPPED - Ship Other'
            WHEN p.pxtxtp='500'                                   THEN 'UNMAPPED - Pack'
            WHEN p.pxtxtp='300'                                   THEN 'UNMAPPED - Carton Maint'
            WHEN p.pxtxtp='700'                                   THEN 'UNMAPPED - Move'
            WHEN p.pxtxtp='608'                                   THEN 'UNMAPPED - 608'
            ELSE CONCAT('UNMAPPED - ', p.pxtxtp,'/',p.pxtxcd)
        END AS tx_label
    FROM dbo.pacwmpixmessage p
    WHERE p.IsDelete IS NULL AND p.pxdcr=@today_pxdcr AND p.pxtxtp!='605'
      AND p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr = @item_filter
    GROUP BY p.pxszcd, p.pxtxtp, p.pxtxcd, p.pxaccd, p.pxrscd, p.pxinat,
        CASE ... -- same CASE as tx_label above
)
SELECT
    sd.inventsizeid, sd.wmslocationid,
    sd.yest_qty, sd.today_qty, sd.delta_qty,
    pd.tx_label, pd.tx_count, pd.pix_qty, pd.pxinat AS inv_attr
FROM sz_delta sd
LEFT JOIN pix_detail pd ON sd.inventsizeid = pd.inventsizeid
ORDER BY sd.inventsizeid, sd.wmslocationid, pd.pix_qty DESC;
*/


-- =============================================================================
-- SECTION 3: PIX type volume trend — is any unmapped type spiking?
-- Compares today_pxdcr vs the prior 7 pxdcr dates to detect anomalies
-- =============================================================================
/*
SELECT
    SUBSTRING(p.pxdcr,3,8) AS dc_date,
    p.pxtxtp,
    p.pxtxcd,
    p.pxrscd,
    CASE
        WHEN p.pxtxtp='618' AND p.pxtxcd='10'               THEN 'Confirm Pick'
        WHEN p.pxtxtp='618' AND p.pxtxcd='55' AND p.pxrscd='IV' THEN 'Pick Short IV'
        WHEN p.pxtxtp='621' AND p.pxtxcd='002'              THEN 'Ship Confirm'
        WHEN p.pxtxtp='500'                                   THEN 'Pack'
        WHEN p.pxtxtp='606' AND p.pxtxcd='03'               THEN '[M] ASN Receipt'
        WHEN p.pxtxtp='620' AND p.pxaccd='03'               THEN '[M] Alloc Fulfill'
        ELSE CONCAT('Other-',p.pxtxtp,'/',p.pxtxcd)
    END AS tx_label,
    COUNT(*) AS tx_count,
    SUM(CAST(p.pxinva AS BIGINT))/10000.0 AS total_pxinva,
    COUNT(DISTINCT p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr) AS distinct_items
FROM dbo.pacwmpixmessage p
WHERE p.IsDelete IS NULL
  AND p.pxdcr >= '020260611'   -- last 7 days (adjust as needed)
  AND p.pxtxtp != '605'
GROUP BY SUBSTRING(p.pxdcr,3,8), p.pxtxtp, p.pxtxcd, p.pxrscd,
    CASE
        WHEN p.pxtxtp='618' AND p.pxtxcd='10'               THEN 'Confirm Pick'
        WHEN p.pxtxtp='618' AND p.pxtxcd='55' AND p.pxrscd='IV' THEN 'Pick Short IV'
        WHEN p.pxtxtp='621' AND p.pxtxcd='002'              THEN 'Ship Confirm'
        WHEN p.pxtxtp='500'                                   THEN 'Pack'
        WHEN p.pxtxtp='606' AND p.pxtxcd='03'               THEN '[M] ASN Receipt'
        WHEN p.pxtxtp='620' AND p.pxaccd='03'               THEN '[M] Alloc Fulfill'
        ELSE CONCAT('Other-',p.pxtxtp,'/',p.pxtxcd)
    END
ORDER BY dc_date DESC, total_pxinva DESC;
*/
