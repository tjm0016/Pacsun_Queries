-- Fiscal-week total of PO receipt cost: costamountposted (pre-landed) vs costamountphysical (full landed)
-- Purpose: see, fiscal week by fiscal week, when/how the landed-cost gap opens up. Daily buckets
-- are too thin - a light-receipt day swings gap_pct wildly on a tiny base. Fiscal week matches the
-- grain the BI report itself uses.
-- Fiscal Week 1 anchor = 2026-02-07 (verified against the BI workbook's own Fiscal Week -> date map:
-- wk22->2026-07-04, wk27->2026-08-08, etc. - confirmed exact match on this anchor/formula).
-- Env: d365-synapse-ps-prod-ondemand.sql.azuresynapse.net / dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Gotchas applied: ISNULL(IsDelete,0)=0 (Synapse Link tombstone), qty>0 (receipts only, not
-- reversals), referencecategory=3 (Purchase Order origin) - see reference-synapse-serverless-gotchas.

SELECT
    1 + DATEDIFF(day, '2026-02-07', it.datephysical) / 7   AS fiscal_week,
    MIN(it.datephysical)                                   AS week_start,
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
WHERE it.dataareaid = '1001'
  AND ISNULL(it.IsDelete, 0) = 0
  AND o.referencecategory = 3            -- Purchase Order
  AND it.qty > 0                         -- receipts only (excludes reversals/negative adjustments)
  AND it.datephysical >= '2026-02-07'    -- Fiscal Week 1 start; guards the DATEDIFF anchor
GROUP BY 1 + DATEDIFF(day, '2026-02-07', it.datephysical) / 7
ORDER BY fiscal_week;
