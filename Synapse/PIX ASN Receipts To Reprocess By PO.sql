-- PIX ASN Receipts To Reprocess (by PO)
-- Source: D365 Synapse (ps-prod). Set @po (10-digit, zero padded) and run.
-- One row per stuck 606/03 ASNReceipt message x PO line. A message posts as ONE journal,
-- so a single bad line blocks every carton in it -> check msg_verdict, not just the row.
-- posted_u comes from vendpackingsliptrans (true receipts, includes manual);
-- nonpix_u = posted_u - pix_ok_u > 0 means units were received outside PIX -> do NOT re-drive those.
DECLARE @po varchar(20) = '0000768307';

WITH pl AS (
    SELECT l.linenumber, l.itemid, d.inventcolorid AS color, d.inventsizeid AS size,
           l.qtyordered, l.overdeliverypct, l.isdeleted, l.purchstatus, l.inventtransid
    FROM purchline l
    LEFT JOIN inventdim d ON d.inventdimid = l.inventdimid AND d.dataareaid = l.dataareaid
    WHERE l.purchid = @po AND l.dataareaid = '1001'
),
rcv AS (
    SELECT t.inventtransid, SUM(t.qty) AS posted_u
    FROM vendpackingslipjour j
    JOIN vendpackingsliptrans t ON t.vendpackingslipjour = j.recid
    WHERE j.purchid = @po
    GROUP BY t.inventtransid
),
pix AS (
    SELECT m.recid AS msg, m.messagestatus AS st, m.statusdatetime,
           TRY_CAST(px.pxpoln AS int) AS poline, px.pxdcr,
           TRY_CAST(px.pxunrc AS bigint) / 10000.0 AS units
    FROM pacwmpixmessage px
    JOIN sunintmessage m ON m.recid = px.message
    WHERE TRY_CAST(px.pxpon AS bigint) = TRY_CAST(@po AS bigint)
      AND px.pxtxtp = '606' AND px.pxtxcd = '03'
),
pix_ok AS (
    SELECT poline, SUM(units) AS pix_ok_u FROM pix WHERE st IN (40, 50) GROUP BY poline
),
stuck AS (
    SELECT msg, st, MAX(statusdatetime) AS statusdatetime, poline, MAX(pxdcr) AS pxdcr,
           COUNT(*) AS cartons, SUM(units) AS stuck_u
    FROM pix WHERE st NOT IN (40, 50)
    GROUP BY msg, st, poline
),
err AS (
    SELECT el.message, CAST(el.errortext AS varchar(400)) AS last_error,
           el.createddatetime, COUNT(*) OVER (PARTITION BY el.message) AS error_count,
           ROW_NUMBER() OVER (PARTITION BY el.message ORDER BY el.createddatetime DESC) AS rn
    FROM sunintmessageerrorlog el
    WHERE el.message IN (SELECT msg FROM stuck)
),
detail AS (
    SELECT s.msg, s.st AS msg_status, s.pxdcr AS wm_date, s.poline,
           pl.itemid, pl.color, pl.size, pl.isdeleted, pl.purchstatus,
           CAST(pl.qtyordered AS int) AS ordered_u,
           CAST(ISNULL(r.posted_u, 0) AS int) AS posted_u,
           CAST(ISNULL(o.pix_ok_u, 0) AS int) AS pix_ok_u,
           CAST(ISNULL(r.posted_u, 0) - ISNULL(o.pix_ok_u, 0) AS int) AS nonpix_u,
           s.cartons, CAST(s.stuck_u AS int) AS stuck_u,
           CAST(ISNULL(r.posted_u, 0) + s.stuck_u AS int) AS total_if_posted,
           CAST(pl.qtyordered * (1 + pl.overdeliverypct / 100.0) AS int) AS overdelivery_cap,
           CASE
             WHEN pl.linenumber IS NULL                          THEN 'BLOCKS - line not on PO'
             WHEN pl.isdeleted = 1                               THEN 'BLOCKS - line deleted'
             WHEN ISNULL(r.posted_u, 0) - ISNULL(o.pix_ok_u, 0) >= s.stuck_u
                                                                 THEN 'ALREADY RECEIVED - close, do not re-drive'
             WHEN ISNULL(r.posted_u, 0) + s.stuck_u > pl.qtyordered * (1 + pl.overdeliverypct / 100.0)
                                                                 THEN 'BLOCKS - over overdelivery cap'
             WHEN ISNULL(r.posted_u, 0) - ISNULL(o.pix_ok_u, 0) > 0
                                                                 THEN 'REVIEW - some units received outside PIX'
             ELSE 'OK'
           END AS line_check,
           e.error_count, e.last_error
    FROM stuck s
    LEFT JOIN pl   ON pl.linenumber = s.poline
    LEFT JOIN rcv r ON r.inventtransid = pl.inventtransid
    LEFT JOIN pix_ok o ON o.poline = s.poline
    LEFT JOIN err e ON e.message = s.msg AND e.rn = 1
)
SELECT d.*,
       CASE
         WHEN SUM(CASE WHEN line_check LIKE 'ALREADY%' THEN 1 ELSE 0 END) OVER (PARTITION BY msg) > 0
              THEN 'DO NOT RE-DRIVE - units received outside PIX; close message'
         WHEN SUM(CASE WHEN line_check LIKE 'BLOCKS%' THEN 1 ELSE 0 END) OVER (PARTITION BY msg) > 0
              THEN 'FIX BLOCKING LINE(S), then re-drive whole message'
         WHEN SUM(CASE WHEN line_check LIKE 'REVIEW%' THEN 1 ELSE 0 END) OVER (PARTITION BY msg) > 0
              THEN 'REVIEW - partial manual receipt; re-drive may double-receive'
         ELSE 'RE-DRIVE'
       END AS msg_verdict,
       SUM(stuck_u) OVER (PARTITION BY msg) AS msg_stuck_u
FROM detail d
ORDER BY msg, poline;
