-- PO-LEVEL fiscal-week total of PO receipt cost: costamountposted vs costamountphysical.
--
-- STRUCTURAL FINDING #1 (2026-09-17, confirmed on 6 example POs then validated at full scale): the
-- BI "Total Company Receipts at Cost" report does NOT bucket each inventtrans row by its own
-- datephysical. It buckets each PURCHASE ORDER by the fiscal week of its FIRST physical receipt,
-- then attributes that PO's ENTIRE CUMULATIVE receipt cost (all waves, however many weeks it keeps
-- receiving) to that one week. E.g. PO 0000767163 received from 6/29/2026 through 9/8/2026 (fiscal
-- weeks 22-32) but BI books its full $236,622 entirely to Fiscal Week 22, because that's when its
-- FIRST unit arrived. Six example POs matched BI's own reported $ within $0.30-$555 (<0.1%) each.
--
-- STRUCTURAL FINDING #2 (2026-09-17, corrects an initial mistake): costamountposted is legitimately
-- $0 on any receipt that has NOT YET been invoiced (purchstatus 1 Open or 2 Received, never reaches
-- 3 Invoiced) - confirmed on several stuck April-2026 (go-live week) POs still sitting un-invoiced
-- 5+ months later. Diffing that $0 against a fully-populated costamountphysical manufactures a huge
-- FAKE landed-cost gap that has nothing to do with the actual costing fix - e.g. fiscal week 9
-- showed an $890K fake gap this way (302 un-invoiced rows alone contributed $729,604 of it), when
-- BI's own report showed ~$0 variance for that whole era. Excluding costamountposted=0 rows from
-- the gap calculation collapses weeks 9-21 back down to near-zero (matching BI) and brings weeks
-- 22-27 into the right order of magnitude vs BI's own reported COST VAR (previously 10-20x too big,
-- now mostly within 2x, week 27 within 13%). The gap_invoiced_only column below is the one to trust;
-- gap_all (kept for reference) is inflated by un-invoiced noise and should NOT be used.
--
-- Residual note: fiscal weeks 22+ still run somewhat higher here than BI's frozen 9/4 snapshot -
-- expected, since this query reads LIVE data and landed-cost corrections have kept landing in the
-- ~2 weeks since BI's pull. Not a bug; a live-vs-point-in-time-snapshot difference.
--
-- Scoped to inventlocationid = '4901' (PO's are basically exclusively received there per Tyler;
-- excludes drop-ship location 4112 and wholesale/CHINO* sites).
--
-- ANCHOR: PacSun FY 4-5-4 calendar, FY2026 starts 2026-02-01 (Sunday), weeks run Sun-Sat.
-- Env: d365-synapse-ps-prod-ondemand.sql.azuresynapse.net / dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Gotchas applied: ISNULL(IsDelete,0)=0 (Synapse Link tombstone), qty>0 (receipts only),
-- referencecategory=3 (Purchase Order origin), excludes the 1900-01-01 sentinel date on
-- placeholder rows when finding each PO's first real receipt date.

WITH po_first AS (
    -- each PO's first TRUE physical receipt date (excludes the 1900 sentinel on placeholder rows)
    SELECT o.referenceid AS purchid, MIN(it.datephysical) AS first_receipt_date
    FROM inventtrans it
    JOIN inventtransorigin o ON o.recid = it.inventtransorigin AND o.dataareaid = it.dataareaid
    WHERE it.dataareaid = '1001' AND ISNULL(it.IsDelete,0) = 0
      AND o.referencecategory = 3 AND it.qty > 0
      AND it.datephysical > '1901-01-01'
    GROUP BY o.referenceid
),
po_totals AS (
    -- each PO's CUMULATIVE receipt cost across its entire history, 4901 only, split so the gap
    -- calc can exclude not-yet-invoiced (costamountposted = 0) rows
    SELECT o.referenceid AS purchid,
           SUM(it.costamountposted)   AS posted_all,
           SUM(it.costamountphysical) AS physical_all,
           SUM(CASE WHEN it.costamountposted <> 0 THEN it.costamountposted   ELSE 0 END) AS posted_invoiced_only,
           SUM(CASE WHEN it.costamountposted <> 0 THEN it.costamountphysical ELSE 0 END) AS physical_invoiced_only,
           SUM(it.qty) AS units
    FROM inventtrans it
    JOIN inventtransorigin o ON o.recid = it.inventtransorigin AND o.dataareaid = it.dataareaid
    LEFT JOIN inventdim id ON id.inventdimid = it.inventdimid AND id.dataareaid = it.dataareaid
    WHERE it.dataareaid = '1001' AND ISNULL(it.IsDelete,0) = 0
      AND o.referencecategory = 3 AND it.qty > 0
      AND id.inventlocationid = '4901'
    GROUP BY o.referenceid
)
SELECT
    1 + DATEDIFF(day, '2026-02-01', f.first_receipt_date) / 7   AS fiscal_week,
    MIN(f.first_receipt_date)                                  AS week_start,
    COUNT(*)                                                   AS n_pos,
    SUM(t.units)                                               AS units,
    SUM(t.posted_all)                                          AS cost_posted_all,      -- includes un-invoiced $0 noise
    SUM(t.physical_all)                                        AS cost_physical_all,    -- includes un-invoiced $0 noise
    SUM(t.posted_invoiced_only)                                AS cost_posted,          -- BI's old "Receipts $ @Cost" proxy
    SUM(t.physical_invoiced_only)                               AS cost_physical,       -- BI's new "Receipts $ @Cost" proxy
    SUM(t.physical_invoiced_only) - SUM(t.posted_invoiced_only) AS gap_invoiced_only     -- TRUST THIS ONE
FROM po_first f
JOIN po_totals t ON t.purchid = f.purchid
WHERE f.first_receipt_date >= '2026-02-01'
GROUP BY 1 + DATEDIFF(day, '2026-02-01', f.first_receipt_date) / 7
ORDER BY fiscal_week;
