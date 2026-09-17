-- Daily total of PO receipt cost: costamountposted (pre-landed) vs costamountphysical (full landed)
-- Purpose: see, day by day, when/how the landed-cost gap opens up (BI "Receipts $ @Cost" flip
-- from posted -> physical exposed a real, growing gap starting ~fiscal wk 21-22 / late June 2026 -
-- this traces it to the day and ties to ISS-01573 duty-percent fix, prod deploy 2026-07-07/08).
-- Env: d365-synapse-ps-prod-ondemand.sql.azuresynapse.net / dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
-- Gotchas applied: ISNULL(IsDelete,0)=0 (Synapse Link tombstone), qty>0 (receipts only, not
-- reversals), referencecategory=3 (Purchase Order origin) - see reference-synapse-serverless-gotchas.

SELECT
    CAST(it.datephysical AS date)              AS receipt_date,
    COUNT(*)                                   AS n_rows,
    SUM(it.qty)                                AS units,
    SUM(it.costamountposted)                   AS cost_posted,      -- pre-landed cost (BI's old "Receipts $ @Cost")
    SUM(it.costamountphysical)                 AS cost_physical,    -- full landed cost (BI's new "Receipts $ @Cost")
    SUM(it.costamountadjustment)               AS gap,              -- = physical - posted
    CASE WHEN SUM(it.costamountposted) <> 0
         THEN SUM(it.costamountadjustment) / SUM(it.costamountposted)
         ELSE NULL END                         AS gap_pct
FROM inventtrans it
JOIN inventtransorigin o
    ON o.recid = it.inventtransorigin
   AND o.dataareaid = it.dataareaid
WHERE it.dataareaid = '1001'
  AND ISNULL(it.IsDelete, 0) = 0
  AND o.referencecategory = 3            -- Purchase Order
  AND it.qty > 0                         -- receipts only (excludes reversals/negative adjustments)
GROUP BY CAST(it.datephysical AS date)
ORDER BY receipt_date;
