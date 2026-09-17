-- FINAL, VALIDATED: fiscal-week total of PO receipt cost, costamountposted vs costamountphysical.
-- (Filename kept for history; this is now the per-TRANSACTION grain, not per-PO - see below.)
--
-- TWO WRONG TURNS CORRECTED ALONG THE WAY (2026-09-17) - kept here so the mistake isn't repeated:
--
-- 1. WRONG: "each PO's entire cumulative total belongs to the fiscal week of its FIRST receipt."
--    This looked right on several hand-picked simple, single-wave POs (matched BI within $0.30-$555)
--    but is FALSE in general. Proof: PO 0000767103, style 0133-60489-0094 color 1, appears in BI
--    across THREE separate fiscal weeks by receiving wave - wk23: 9,953u/$123,206, wk24: 60u/$743,
--    wk25: 240u/$2,971. A PO-cumulative query crams all 10,253 units into one week; BI does not.
--    The correct grain is per-transaction datephysical, exactly like a naive first attempt - the
--    PO-cumulative theory was an overcorrection that fixed a different bug (see #2) for the wrong
--    reason.
--
-- 2. RIGHT, and still needed: costamountposted is legitimately $0 on any receipt not yet invoiced
--    (purchstatus 1/2, never reaches 3-Invoiced). Diffing that $0 against a populated
--    costamountphysical manufactures a fake gap. Excluding costamountposted=0 rows from BOTH sums
--    (not just from posted) is required - confirmed this alone took fiscal week 9's total from an
--    $890K fake gap down to essentially flat, matching BI's own reported ~$0 variance for that era.
--
-- VALIDATED at full scale (per-transaction datephysical + 4901 + invoiced-only): 11 of 12 weeks
-- checked land within 1-7% of BI's own reported total (posted side); fiscal week 27 (closest to
-- BI's own report cutoff) runs ~17-19% short, most likely because more of that week's activity is
-- still genuinely un-invoiced as of today than in older, fully-settled weeks - not chased further.
-- Also validated exactly (to the dollar) on PO 0000767103's three-way wave split above.
--
-- Scoped to inventlocationid = '4901' (PO's are basically exclusively received there per Tyler;
-- excludes drop-ship location 4112 and wholesale/CHINO* sites).
--
-- ANCHOR: PacSun FY 4-5-4 calendar, FY2026 starts 2026-02-01 (Sunday), weeks run Sun-Sat - confirmed
-- against the D365 Fiscal calendars screen (the workbook's own "FW" column stores the week-ENDING
-- Saturday, not the start - don't use it directly as an anchor).
--
-- Env: d365-synapse-ps-prod-ondemand.sql.azuresynapse.net / dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Gotchas applied: ISNULL(IsDelete,0)=0 (Synapse Link tombstone), qty>0 (receipts only, not
-- reversals), referencecategory=3 (Purchase Order origin).

SELECT
    1 + DATEDIFF(day, '2026-02-01', it.datephysical) / 7   AS fiscal_week,
    MIN(it.datephysical)                                   AS week_start,
    COUNT(*)                                                AS n_rows,
    SUM(it.qty)                                             AS units,
    SUM(CASE WHEN it.costamountposted <> 0 THEN it.costamountposted   ELSE 0 END) AS cost_posted,    -- excludes not-yet-invoiced rows; BI's old "Receipts $ @Cost" proxy
    SUM(CASE WHEN it.costamountposted <> 0 THEN it.costamountphysical ELSE 0 END) AS cost_physical,  -- excludes not-yet-invoiced rows; BI's new "Receipts $ @Cost" proxy
    SUM(CASE WHEN it.costamountposted <> 0 THEN it.costamountphysical - it.costamountposted ELSE 0 END) AS gap
FROM inventtrans it
JOIN inventtransorigin o
    ON o.recid = it.inventtransorigin
   AND o.dataareaid = it.dataareaid
LEFT JOIN inventdim id
    ON id.inventdimid = it.inventdimid
   AND id.dataareaid = it.dataareaid
WHERE it.dataareaid = '1001'
  AND ISNULL(it.IsDelete, 0) = 0
  AND o.referencecategory = 3            -- Purchase Order
  AND it.qty > 0                         -- receipts only (excludes reversals/negative adjustments)
  AND id.inventlocationid = '4901'       -- Retail DC only - excludes drop-ship (4112) and wholesale
  AND it.datephysical >= '2026-02-01'    -- Fiscal Week 1 start (FY2026, 4-5-4 calendar); guards the DATEDIFF anchor
GROUP BY 1 + DATEDIFF(day, '2026-02-01', it.datephysical) / 7
ORDER BY fiscal_week;
