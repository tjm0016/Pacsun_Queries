-- Fiscal-week total of PO receipt cost at 4901 RETAIL DC ONLY: costamountposted (pre-landed) vs
-- costamountphysical (full landed).
--
-- Scoped to inventlocationid = '4901' per Tyler: PO's are basically exclusively received there.
-- This excludes: wholesale/CHINO* sites, and '4112 - DROP SHIP' (a virtual location carrying
-- ~10K thin cost-only rows at ~$20/row in a single fiscal week sample - not physical DC receipts).
--
-- Open question (2026-09-17): restricting to 4901-only gets cost_physical within ~0.3% of the BI
-- pivot's own 9.4 PROD figure for FW22, but cost_posted comes in ~$311K SHORT of the BI 8.12 PROD
-- figure for the same week - and that shortfall is almost exactly what sits in the excluded
-- drop-ship + wholesale rows. Unclear whether BI's "posted" side scopes wider than "physical" (i.e.
-- whether drop-ship cost postings are meant to count as "receipts") - unresolved, business call.
--
-- ANCHOR: PacSun FY 4-5-4 calendar, FY2026 starts 2026-02-01 (Sunday), weeks run Sun-Sat - confirmed
-- against the D365 Fiscal calendars screen. The workbook's own "FW" column stores the week-ENDING
-- Saturday, not the start.
--
-- Env: d365-synapse-ps-prod-ondemand.sql.azuresynapse.net / dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Gotchas applied: ISNULL(IsDelete,0)=0 (Synapse Link tombstone), qty>0 (receipts only, not
-- reversals), referencecategory=3 (Purchase Order origin) - see reference-synapse-serverless-gotchas.

SELECT
    1 + DATEDIFF(day, '2026-02-01', it.datephysical) / 7   AS fiscal_week,
    MIN(it.datephysical)                                   AS week_start,
    MAX(it.datephysical)                                   AS week_end,
    COUNT(*)                                               AS n_rows,
    SUM(it.qty)                                            AS units,
    SUM(it.costamountposted)                               AS cost_posted,      -- pre-landed cost (BI's old "Receipts $ @Cost")
    SUM(it.costamountphysical)                             AS cost_physical,    -- full landed cost (BI's new "Receipts $ @Cost")
    SUM(it.costamountadjustment)                           AS gap,              -- = physical - posted
    CASE WHEN SUM(it.costamountposted) <> 0
         THEN SUM(it.costamountadjustment) / SUM(it.costamountposted)
         ELSE NULL END                                     AS gap_pct
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
