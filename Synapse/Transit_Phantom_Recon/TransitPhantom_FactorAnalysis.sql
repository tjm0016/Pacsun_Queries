-- Transit warehouse in-transit inflation: factor analysis + validation queries.
-- Backs every number in Chain_Transit_Phantom_Recon_Summary.pdf beyond the three core
-- queries (see TransitPhantom_SummaryByStore / _SkuDetailDiffs / _FixJournalQtyAtT).
-- Synapse serverless prod, base tables, dataareaid 1001. Data as of 2026-07-31.
-- Every section is standalone - run any block on its own.

-- ============================================================================
-- S1. SANITY: transit warehouse count / duplicate open-carton headers /
--     store-73 anchor (should give 397; 16221 = 16221; 776 vs 681).
-- ============================================================================
SELECT COUNT(*) AS transit_whs
FROM inventlocation
WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
  AND inventlocationtype = 2 AND inventlocationid LIKE '%-T';

SELECT COUNT(*) AS hdr_rows, COUNT(DISTINCT cartonnumber) AS distinct_cartons
FROM paccartontransferheader
WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
  AND shippeddatetime > '1900-01-01' AND receiveddatetime = '1900-01-01';

SELECT
  (SELECT SUM(s.physicalinvent)
   FROM inventsum s
   JOIN inventdim d ON s.inventdimid=d.inventdimid AND s.dataareaid=d.dataareaid AND s.partition=d.partition
   WHERE s.dataareaid='1001' AND ISNULL(s.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
     AND d.inventlocationid='0073-T') AS onhand_0073T,
  (SELECT SUM(l.cartonquantity)
   FROM paccartontransferheader h
   JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
   WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
     AND h.towh='0073'
     AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01') AS open_cartons_0073;

-- ============================================================================
-- F1. Open-carton AGE BUCKETS per store (dead cartons = anything > 14 days).
--     Chain rollup: 0-7d 543,382u | 8-14d 27,690u | >14d 44,685u (1,321 cartons).
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT h.towh COLLATE DATABASE_DEFAULT AS storewh,
       CASE WHEN h.shippeddatetime >= DATEADD(day,-7,GETUTCDATE())  THEN 'a_0_7d'
            WHEN h.shippeddatetime >= DATEADD(day,-14,GETUTCDATE()) THEN 'b_8_14d'
            WHEN h.shippeddatetime >= DATEADD(day,-21,GETUTCDATE()) THEN 'c_15_21d'
            WHEN h.shippeddatetime >= DATEADD(day,-35,GETUTCDATE()) THEN 'd_22_35d'
            WHEN h.shippeddatetime >= DATEADD(day,-60,GETUTCDATE()) THEN 'e_36_60d'
            ELSE 'f_over60d' END AS age_bucket,
       COUNT(DISTINCT h.cartonnumber) AS cartons,
       SUM(l.cartonquantity) AS units
FROM paccartontransferheader h
JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
  AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
  AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
GROUP BY h.towh,
       CASE WHEN h.shippeddatetime >= DATEADD(day,-7,GETUTCDATE())  THEN 'a_0_7d'
            WHEN h.shippeddatetime >= DATEADD(day,-14,GETUTCDATE()) THEN 'b_8_14d'
            WHEN h.shippeddatetime >= DATEADD(day,-21,GETUTCDATE()) THEN 'c_15_21d'
            WHEN h.shippeddatetime >= DATEADD(day,-35,GETUTCDATE()) THEN 'd_22_35d'
            WHEN h.shippeddatetime >= DATEADD(day,-60,GETUTCDATE()) THEN 'e_36_60d'
            ELSE 'f_over60d' END;

-- ============================================================================
-- F2. Open cartons that already show RECEIVED qty on their lines
--     (received-but-never-closed leak; result: only 1 carton / 18 units chain-wide).
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
),
perc AS (
  SELECT h.towh COLLATE DATABASE_DEFAULT AS storewh, h.cartonnumber,
         SUM(l.cartonquantity) AS carton_units, SUM(l.receivedquantity) AS received_units
  FROM paccartontransferheader h
  JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
  WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
    AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
    AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
  GROUP BY h.towh, h.cartonnumber
)
SELECT storewh, COUNT(*) AS cartons, SUM(carton_units) AS carton_units, SUM(received_units) AS received_units
FROM perc
WHERE received_units > 0
GROUP BY storewh;

-- ============================================================================
-- F3. Open cartons by header cartonstatus (0=Created, 1=Acked, 2=In Transit, 4=Received).
--     Result: 50 status-0 (5,428u), 10,277 status-1, 5,888 status-2, 4 status-4 (193u).
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT h.cartonstatus, COUNT(DISTINCT h.cartonnumber) AS cartons, SUM(l.cartonquantity) AS units
FROM paccartontransferheader h
JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
  AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
  AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
GROUP BY h.cartonstatus;

-- ============================================================================
-- F4. BROKEN RECEIVE TIMESTAMPS: receiveddatetime = 1900-01-01 + time-of-day
--     (date lost, time kept). By status - result: ALL 13,061 cartons / 560,344
--     units are cartonstatus 4 Received, so the open/received split is unaffected.
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT h.cartonstatus, COUNT(DISTINCT h.cartonnumber) AS cartons, SUM(l.cartonquantity) AS units
FROM paccartontransferheader h
JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
  AND h.shippeddatetime > '1900-01-01'
  AND h.receiveddatetime > '1900-01-01' AND h.receiveddatetime < '1900-01-02'
  AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
GROUP BY h.cartonstatus;

-- ============================================================================
-- F5. FULL -T FLOW DECOMPOSITION: everything ever posted into/out of the -T
--     warehouses by journal type. SUM(net_qty) ties exactly to inventsum on-hand
--     (663,483 on 2026-07-31). statusreceipt>0 rows = receipts, statusissue>0 = issues.
--     Key results: CTN-TRANSFER +376,625 | MOV-MIG +411,352 (exact 2:1 in/out) |
--     CTN-MOV -241,766 | fix journals +96,536 | MOV-DONATE +19,860 | MOV-DCADJ +11,207.
-- ============================================================================
SELECT o.referencecategory,
       jt.journalnameid COLLATE DATABASE_DEFAULT AS journalnameid,
       CASE WHEN o.referenceid COLLATE DATABASE_DEFAULT IN ('INV-01139040','INV-01139054')
            THEN 'FIXJRN' ELSE '' END AS fixflag,
       CASE WHEN t.datephysical < '2026-04-05' THEN 'pre_golive' ELSE 'post_golive' END AS era,
       t.statusreceipt, t.statusissue,
       SUM(t.qty) AS net_qty, COUNT(*) AS trans_rows
FROM inventtrans t
JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
LEFT JOIN inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = o.referenceid COLLATE DATABASE_DEFAULT
     AND jt.dataareaid = '1001' AND ISNULL(jt.IsDelete,0)=0
WHERE t.dataareaid='1001'
  AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
  AND d.inventlocationid LIKE '%-T'
GROUP BY o.referencecategory, jt.journalnameid,
       CASE WHEN o.referenceid COLLATE DATABASE_DEFAULT IN ('INV-01139040','INV-01139054')
            THEN 'FIXJRN' ELSE '' END,
       CASE WHEN t.datephysical < '2026-04-05' THEN 'pre_golive' ELSE 'post_golive' END,
       t.statusreceipt, t.statusissue;

-- ============================================================================
-- D2. DEAD open cartons (>14d) by SHIPPED MONTH (oldest = 2024-10).
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT FORMAT(h.shippeddatetime,'yyyy-MM') AS ship_month,
       COUNT(DISTINCT h.cartonnumber) AS cartons, SUM(l.cartonquantity) AS units
FROM paccartontransferheader h
JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
  AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
  AND h.shippeddatetime < DATEADD(day,-14,GETUTCDATE())
  AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
GROUP BY FORMAT(h.shippeddatetime,'yyyy-MM')
ORDER BY ship_month;

-- ============================================================================
-- D3. DEAD open-carton units (>14d), top stores.
-- ============================================================================
WITH transit AS (
  SELECT REPLACE(inventlocationid, '-T', '') COLLATE DATABASE_DEFAULT AS storewh
  FROM inventlocation
  WHERE dataareaid='1001' AND ISNULL(IsDelete,0)=0
    AND inventlocationtype = 2 AND inventlocationid LIKE '%-T'
)
SELECT TOP 15 h.towh AS storewh,
       COUNT(DISTINCT h.cartonnumber) AS cartons, SUM(l.cartonquantity) AS units
FROM paccartontransferheader h
JOIN paccartontransferline l ON l.cartonnumber=h.cartonnumber AND l.dataareaid=h.dataareaid AND l.partition=h.partition
WHERE h.dataareaid='1001' AND ISNULL(h.IsDelete,0)=0 AND ISNULL(l.IsDelete,0)=0
  AND h.shippeddatetime > '1900-01-01' AND h.receiveddatetime = '1900-01-01'
  AND h.shippeddatetime < DATEADD(day,-14,GETUTCDATE())
  AND h.towh COLLATE DATABASE_DEFAULT IN (SELECT storewh FROM transit)
GROUP BY h.towh
ORDER BY SUM(l.cartonquantity) DESC;
