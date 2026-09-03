/* ============================================================================
   PO RECEIPT RECON - wmsjournaltrans (WM ASN arrival) vs vendpackingsliptrans
   ----------------------------------------------------------------------------
   Answers: for a PO, what did WM actually receive vs what is POSTED as a
   product receipt, and how much of the gap is a manual (MG) receipt vs a
   stale unposted arrival journal.

   Join rules that matter (do not "simplify" these):
     - PO comes off the LINES: wmsjournaltrans.inventtransrefid.
       wmsjournaltable.inventtransrefid (header) is NULL on ~3.4% of WM ASN
       journals and is occasionally cross-stamped with a DIFFERENT PO.
     - ASN / posted / posteddatetime come off the HEADER, joined on journalid.
     - Packing slips key on vendpackingsliptrans.origpurchid, NOT purchid.
     - posted = 0 arrival journals are the ASN RESIDUAL (the not-yet-received
       balance), not a receipt. They go stale and are never cleaned up.
     - packingslipid LIKE 'MG%' = manual product receipt keyed in D365; it has
       NO wmsjournaltrans rows by design (never touched WM).
     - vendpackingsliptrans.createddatetime is often the 1900 sentinel; date
       the receipt off deliverydate instead.
   Serverless quirks: ISNULL(IsDelete,0)=0 (live rows are NULL, not 0) and
   COLLATE DATABASE_DEFAULT on every text join / literal.
   ============================================================================ */

DECLARE @po1 varchar(20) = '0000765542';
DECLARE @po2 varchar(20) = '0000765899';

/* -------- 1. Totals per PO: ordered / WM arrival / posted receipts -------- */
WITH ord AS (
    SELECT p.purchid AS po,
           SUM(p.qtyordered)          AS ordered,
           SUM(p.remainpurchphysical) AS po_open_remain,
           MAX(p.purchstatus)         AS purchstatus   -- 1=Open 2=Received 3=Invoiced 4=Canceled
    FROM purchline p
    WHERE p.dataareaid = '1001' AND ISNULL(p.IsDelete,0) = 0
      AND p.purchid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY p.purchid
),
wms AS (
    SELECT t.inventtransrefid AS po,
           SUM(CASE WHEN h.posted = 1 THEN t.qty ELSE 0 END) AS wms_posted,
           SUM(CASE WHEN h.posted = 0 THEN t.qty ELSE 0 END) AS wms_unposted_residual,
           COUNT(DISTINCT CASE WHEN h.posted = 1 THEN t.journalid END) AS posted_journals
    FROM wmsjournaltrans t
    JOIN wmsjournaltable h
      ON h.journalid  COLLATE DATABASE_DEFAULT = t.journalid  COLLATE DATABASE_DEFAULT
     AND h.dataareaid COLLATE DATABASE_DEFAULT = t.dataareaid COLLATE DATABASE_DEFAULT
     AND ISNULL(h.IsDelete,0) = 0
    WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0
      AND t.inventtransrefid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY t.inventtransrefid
),
ps AS (
    SELECT v.origpurchid AS po,
           SUM(CASE WHEN v.packingslipid COLLATE DATABASE_DEFAULT LIKE 'MG%' THEN 0 ELSE v.qty END) AS ps_wm_driven,
           SUM(CASE WHEN v.packingslipid COLLATE DATABASE_DEFAULT LIKE 'MG%' THEN v.qty ELSE 0 END) AS ps_manual,
           SUM(v.qty) AS ps_total,
           COUNT(DISTINCT v.packingslipid) AS slips
    FROM vendpackingsliptrans v
    WHERE v.dataareaid = '1001' AND ISNULL(v.IsDelete,0) = 0
      AND v.origpurchid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY v.origpurchid
)
SELECT o.po, o.ordered, o.purchstatus,
       w.wms_posted, w.posted_journals,
       s.ps_wm_driven, s.ps_manual, s.ps_total, s.slips,
       s.ps_wm_driven - w.wms_posted AS wm_vs_slip_delta,      -- expect 0
       o.ordered - s.ps_total        AS never_received,
       o.po_open_remain,
       w.wms_unposted_residual,
       w.wms_unposted_residual - o.po_open_remain AS stale_residual  -- phantom "pending receipt"
FROM ord o
LEFT JOIN wms w ON w.po COLLATE DATABASE_DEFAULT = o.po COLLATE DATABASE_DEFAULT
LEFT JOIN ps  s ON s.po COLLATE DATABASE_DEFAULT = o.po COLLATE DATABASE_DEFAULT
ORDER BY o.po;

/* -------- 2. Packing slip detail (the posted receipts) -------- */
SELECT v.origpurchid AS po, v.packingslipid,
       CASE WHEN v.packingslipid COLLATE DATABASE_DEFAULT LIKE 'MG%' THEN 'MANUAL' ELSE 'WM ASN' END AS source,
       CONVERT(varchar(10), MIN(v.deliverydate), 120) AS deliverydate,
       COUNT(*) AS lines_cnt, SUM(v.qty) AS qty, MAX(v.itemid) AS itemid
FROM vendpackingsliptrans v
WHERE v.dataareaid = '1001' AND ISNULL(v.IsDelete,0) = 0
  AND v.origpurchid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
GROUP BY v.origpurchid, v.packingslipid
ORDER BY po, deliverydate, v.packingslipid;

/* -------- 3. WM arrival journal detail (ASN off the header) -------- */
SELECT t.inventtransrefid AS po, t.journalid, h.pacasnid, h.posted,
       CONVERT(varchar(19), h.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time', 120) AS posted_pt,
       COUNT(*) AS lines_cnt, SUM(t.qty) AS qty
FROM wmsjournaltrans t
JOIN wmsjournaltable h
  ON h.journalid  COLLATE DATABASE_DEFAULT = t.journalid  COLLATE DATABASE_DEFAULT
 AND h.dataareaid COLLATE DATABASE_DEFAULT = t.dataareaid COLLATE DATABASE_DEFAULT
 AND ISNULL(h.IsDelete,0) = 0
WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0
  AND t.inventtransrefid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
GROUP BY t.inventtransrefid, t.journalid, h.pacasnid, h.posted, h.posteddatetime
ORDER BY po, h.posted, posted_pt;

/* -------- 4. Size-level recon -------- */
WITH ord AS (
    SELECT p.purchid AS po, d.inventsizeid AS sz,
           SUM(p.qtyordered) AS ordered, SUM(p.remainpurchphysical) AS remain
    FROM purchline p
    JOIN inventdim d
      ON d.inventdimid COLLATE DATABASE_DEFAULT = p.inventdimid COLLATE DATABASE_DEFAULT
     AND d.dataareaid  COLLATE DATABASE_DEFAULT = p.dataareaid  COLLATE DATABASE_DEFAULT
     AND ISNULL(d.IsDelete,0) = 0
    WHERE p.dataareaid = '1001' AND ISNULL(p.IsDelete,0) = 0
      AND p.purchid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY p.purchid, d.inventsizeid
),
wms AS (
    SELECT t.inventtransrefid AS po, d.inventsizeid AS sz,
           SUM(CASE WHEN h.posted = 1 THEN t.qty ELSE 0 END) AS wms_posted,
           SUM(CASE WHEN h.posted = 0 THEN t.qty ELSE 0 END) AS wms_open
    FROM wmsjournaltrans t
    JOIN wmsjournaltable h
      ON h.journalid  COLLATE DATABASE_DEFAULT = t.journalid  COLLATE DATABASE_DEFAULT
     AND h.dataareaid COLLATE DATABASE_DEFAULT = t.dataareaid COLLATE DATABASE_DEFAULT
     AND ISNULL(h.IsDelete,0) = 0
    JOIN inventdim d
      ON d.inventdimid COLLATE DATABASE_DEFAULT = t.inventdimid COLLATE DATABASE_DEFAULT
     AND d.dataareaid  COLLATE DATABASE_DEFAULT = t.dataareaid  COLLATE DATABASE_DEFAULT
     AND ISNULL(d.IsDelete,0) = 0
    WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0
      AND t.inventtransrefid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY t.inventtransrefid, d.inventsizeid
),
ps AS (
    SELECT v.origpurchid AS po, d.inventsizeid AS sz,
           SUM(CASE WHEN v.packingslipid COLLATE DATABASE_DEFAULT LIKE 'MG%' THEN 0 ELSE v.qty END) AS ps_wm,
           SUM(CASE WHEN v.packingslipid COLLATE DATABASE_DEFAULT LIKE 'MG%' THEN v.qty ELSE 0 END) AS ps_manual
    FROM vendpackingsliptrans v
    JOIN inventdim d
      ON d.inventdimid COLLATE DATABASE_DEFAULT = v.inventdimid COLLATE DATABASE_DEFAULT
     AND d.dataareaid  COLLATE DATABASE_DEFAULT = v.dataareaid  COLLATE DATABASE_DEFAULT
     AND ISNULL(d.IsDelete,0) = 0
    WHERE v.dataareaid = '1001' AND ISNULL(v.IsDelete,0) = 0
      AND v.origpurchid COLLATE DATABASE_DEFAULT IN (@po1, @po2)
    GROUP BY v.origpurchid, d.inventsizeid
)
SELECT COALESCE(o.po, w.po, s.po) AS po,
       COALESCE(o.sz, w.sz, s.sz) AS size,
       o.ordered, w.wms_posted, s.ps_wm, s.ps_manual,
       ISNULL(s.ps_wm,0) + ISNULL(s.ps_manual,0) AS received_total,
       o.remain AS po_open_remain,
       w.wms_open AS unposted_arrival
FROM ord o
FULL JOIN wms w
  ON w.po COLLATE DATABASE_DEFAULT = o.po COLLATE DATABASE_DEFAULT
 AND w.sz COLLATE DATABASE_DEFAULT = o.sz COLLATE DATABASE_DEFAULT
FULL JOIN ps s
  ON s.po COLLATE DATABASE_DEFAULT = COALESCE(o.po, w.po) COLLATE DATABASE_DEFAULT
 AND s.sz COLLATE DATABASE_DEFAULT = COALESCE(o.sz, w.sz) COLLATE DATABASE_DEFAULT
ORDER BY po, size;
