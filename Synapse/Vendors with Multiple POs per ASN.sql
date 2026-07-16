-- ============================================================================
-- VENDORS WITH MULTIPLE POs ON THE SAME ASN
-- Server : d365-synapse-ps-prod-ondemand.sql.azuresynapse.net
-- DB     : dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc
--
-- Source : dbo.pacasncartondata — one row per ASN carton line, carrying
--          asnid / purchid / vendor directly, so no ASN-header join is needed.
--
-- Gotchas encoded below (each cost a wrong answer on the way to this query):
--   1. IsDelete is NULL for live rows, NOT 0. Filtering `IsDelete = 0` returns
--      ZERO rows. Use ISNULL(IsDelete, 0) = 0. The 1,000 IsDelete=1 rows are
--      exactly the 1,000 rows with a null asnid.
--   2. vendtable holds each accountnum in TWO legal entities (10 and 1001), so
--      joining on accountnum alone DOUBLES every count. pacasncartondata is
--      100% dataareaid='1001', so the join is pinned to 1001.
--   3. Serverless pool throws collation conflicts on cross-table string joins —
--      hence COLLATE DATABASE_DEFAULT on both sides.
--
-- Verified 2026-07-16: 6,030 ASNs total, 102 with >1 PO, across 28 vendors.
--          No ASN spans more than one vendor, so (asnid, vendor) is 1:1 with
--          asnid and the vendor attribution is unambiguous.
-- ============================================================================

WITH live AS (
    SELECT asnid, vendor, purchid
    FROM dbo.pacasncartondata
    WHERE ISNULL(IsDelete, 0) = 0
      AND asnid IS NOT NULL
      AND asnid <> ''
),
multi AS (          -- ASNs carrying more than one PO
    SELECT asnid, vendor, COUNT(DISTINCT purchid) AS po_cnt
    FROM live
    GROUP BY asnid, vendor
    HAVING COUNT(DISTINCT purchid) > 1
),
tot AS (            -- denominator: every ASN the vendor sent
    SELECT vendor, COUNT(DISTINCT asnid) AS total_asns
    FROM live
    GROUP BY vendor
)
SELECT m.vendor,
       ISNULL(p.name, '(no name)')                                AS vendor_name,
       COUNT(*)                                                   AS multi_po_asns,
       t.total_asns,
       CAST(100.0 * COUNT(*) / t.total_asns AS DECIMAL(5,1))      AS pct_of_their_asns,
       MAX(m.po_cnt)                                              AS max_pos_on_one_asn
FROM multi m
JOIN tot t
  ON t.vendor = m.vendor
LEFT JOIN dbo.vendtable v
       ON v.accountnum COLLATE DATABASE_DEFAULT = m.vendor COLLATE DATABASE_DEFAULT
      AND v.dataareaid COLLATE DATABASE_DEFAULT = '1001'
      AND ISNULL(v.IsDelete, 0) = 0
LEFT JOIN dbo.dirpartytable p
       ON p.recid = v.party
      AND ISNULL(p.IsDelete, 0) = 0
GROUP BY m.vendor, p.name, t.total_asns
ORDER BY multi_po_asns DESC, m.vendor;


-- ============================================================================
-- Sanity check — run alongside the above. asns_multi_po MUST equal the row
-- count of the main query's SUM(multi_po_asns); if it doesn't, a join is
-- fanning out (see gotcha #2).
-- ============================================================================
-- WITH live AS (
--     SELECT asnid, vendor, purchid
--     FROM dbo.pacasncartondata
--     WHERE ISNULL(IsDelete, 0) = 0 AND asnid IS NOT NULL AND asnid <> ''
-- )
-- SELECT
--   (SELECT COUNT(DISTINCT asnid) FROM live) AS asns_total,
--   (SELECT COUNT(*) FROM (SELECT asnid FROM live
--       GROUP BY asnid HAVING COUNT(DISTINCT vendor) > 1) a) AS asns_multi_vendor,
--   (SELECT COUNT(*) FROM (SELECT asnid FROM live
--       GROUP BY asnid HAVING COUNT(DISTINCT purchid) > 1) b) AS asns_multi_po;
