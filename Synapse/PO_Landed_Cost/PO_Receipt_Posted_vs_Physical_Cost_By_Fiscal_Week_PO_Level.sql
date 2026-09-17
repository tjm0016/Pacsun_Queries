-- PO-LEVEL fiscal-week total of PO receipt cost: costamountposted vs costamountphysical.
--
-- KEY FINDING (2026-09-17, confirmed on 6 example POs then validated at full scale): the BI
-- "Total Company Receipts at Cost" report does NOT bucket each inventtrans row by its own
-- datephysical. It buckets each PURCHASE ORDER by the fiscal week of its FIRST physical receipt,
-- then attributes that PO's ENTIRE CUMULATIVE receipt cost (all waves, however many weeks it
-- keeps receiving) to that one week. E.g. PO 0000767163 received from 6/29/2026 through 9/8/2026
-- (fiscal weeks 22-32) but BI books its full $236,622 entirely to Fiscal Week 22, because that's
-- when its FIRST unit arrived. Six example POs matched BI's own reported $ within $0.30-$555
-- (<0.1%) each using this logic, vs. being off by 2x+ or wrong-signed under naive per-transaction
-- date bucketing.
--
-- Validated at full scale against the BI pivot's own weekly totals: most weeks land within 1-8%
-- (a major improvement over per-transaction bucketing, which was off by as much as 2x). Known
-- residual gaps: fiscal week 27 still runs meaningfully short here - possibly because BI's 8.12
-- PROD pull is a POINT-IN-TIME SNAPSHOT as of 2026-08-12, while this query sums each PO to its
-- CURRENT/LIVE state - a PO whose first receipt landed just before 8/12 may have posted more
-- since then than it had as of the snapshot date. Not yet resolved.
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
    -- each PO's CUMULATIVE receipt cost across its entire history, 4901 only
    SELECT o.referenceid AS purchid,
           SUM(it.costamountposted)   AS posted,
           SUM(it.costamountphysical) AS physical,
           SUM(it.qty)                AS units
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
    SUM(t.posted)                                              AS cost_posted,      -- pre-landed (BI's old "Receipts $ @Cost")
    SUM(t.physical)                                            AS cost_physical,    -- full landed (BI's new "Receipts $ @Cost")
    SUM(t.physical) - SUM(t.posted)                            AS gap
FROM po_first f
JOIN po_totals t ON t.purchid = f.purchid
WHERE f.first_receipt_date >= '2026-02-01'
GROUP BY 1 + DATEDIFF(day, '2026-02-01', f.first_receipt_date) / 7
ORDER BY fiscal_week;
