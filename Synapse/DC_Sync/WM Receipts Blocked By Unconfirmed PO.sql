/* =====================================================================================
   WM Receipts Blocked By Unconfirmed PO                              (Synapse - D365 prod)
   -------------------------------------------------------------------------------------
   WM sends a 606/03 ASN receipt, but D365 cannot post it because the PO is not confirmed
   (usually sitting in the approval workflow after a change). D365 still posts the WM
   unlock (606/02/20 Lock_Code -, 300/01/20 Active +), so Lock_Code goes negative and the
   nightly COU-DCSYNC counts the units back up as found stock (e.g. PO 0001382717,
   9/28/2026: +9,195 u / +$129K on one journal).

   Part 1 = receipts that already failed (after the fact).
   Part 2 = POs that are NOT confirmed right now but have open receipt qty (before the fact).
   Set @days for the lookback.
   ===================================================================================== */

DECLARE @days int = 14;
DECLARE @from datetime2 = DATEADD(day, -@days, SYSUTCDATETIME());

/* ---------- Part 1: 606/03 receipts whose posting errored on "no longer confirmed" ---------- */
WITH rcpt AS (   -- WM receipt lines, one row per PIX message line
    SELECT p.message, p.pxpon AS purchid, p.pxdcr,
           p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr AS itemid,
           CAST(p.pxinva AS decimal(18,2)) / 10000 AS qty,
           p.createddatetime
    FROM dbo.pacwmpixmessage p
    WHERE p.pxtxtp = '606' AND p.pxtxcd = '03'
      AND p.createddatetime >= @from
),
err AS (         -- the posting errors on those messages
    SELECT e.message,
           MIN(e.createddatetime) AS first_err_utc,
           MAX(e.createddatetime) AS last_err_utc,
           COUNT(*) AS err_count
    FROM dbo.sunintmessageerrorlog e
    WHERE e.createddatetime >= @from
      AND e.errortext LIKE '%no longer confirmed%'
    GROUP BY e.message
),
bad AS (
    SELECT r.purchid, r.itemid,
           MIN(r.pxdcr) AS wm_day,
           COUNT(DISTINCT r.message) AS msgs,
           SUM(r.qty) AS wm_received_qty,
           MIN(DATEADD(hour, -7, x.first_err_utc)) AS first_err_pt,
           MAX(DATEADD(hour, -7, x.last_err_utc))  AS last_err_pt,
           SUM(x.err_count) AS errors
    FROM rcpt r
    JOIN err x ON x.message = r.message
    GROUP BY r.purchid, r.itemid
),
posted AS (      -- what D365 has actually received on the PO (statusreceipt 1=Purchased, 2=Received)
    SELECT o.referenceid AS purchid, t.itemid,
           SUM(CASE WHEN t.statusreceipt IN (1,2) THEN t.qty ELSE 0 END) AS d365_received_qty,
           SUM(CASE WHEN t.statusreceipt = 5      THEN t.qty ELSE 0 END) AS d365_still_ordered
    FROM dbo.inventtrans t
    JOIN dbo.inventtransorigin o ON o.recid = t.inventtransorigin
    WHERE o.referencecategory = 3
      AND o.referenceid IN (SELECT purchid FROM bad)
    GROUP BY o.referenceid, t.itemid
)
SELECT b.purchid, b.itemid, b.wm_day, b.msgs, b.errors,
       b.wm_received_qty,
       ISNULL(p.d365_received_qty, 0)  AS d365_received_qty,
       ISNULL(p.d365_still_ordered, 0) AS d365_still_ordered,
       CASE WHEN ISNULL(p.d365_received_qty, 0) >= b.wm_received_qty THEN 'RECOVERED'
            ELSE 'STILL NOT RECEIVED - re-drive receipt' END AS receipt_state,
       CASE pt.documentstate WHEN 40 THEN 'Confirmed' WHEN 0 THEN 'Draft'
            WHEN 10 THEN 'In review' WHEN 20 THEN 'Approved' WHEN 30 THEN 'Rejected'
            ELSE CAST(pt.documentstate AS varchar(10)) END AS po_state_now,
       b.first_err_pt, b.last_err_pt,
       DATEADD(hour, -7, pt.modifieddatetime) AS po_modified_pt, pt.modifiedby AS po_modified_by
FROM bad b
LEFT JOIN posted p ON p.purchid = b.purchid AND p.itemid = b.itemid
LEFT JOIN dbo.purchtable pt ON pt.purchid = b.purchid
ORDER BY b.first_err_pt DESC;
GO

/* ---------- Part 2: AT RISK - POs NOT confirmed right now that have an ASN and open qty ---------- */
/* An ASN means freight is on its way to the DC; any WM receipt against these will fail.            */
/* (Drafts with no ASN are left out - they are not shipping yet.)                                   */
DECLARE @days2 int = 30;
WITH asn AS (
    SELECT a.purchid, COUNT(DISTINCT a.asnid) AS asns, COUNT(DISTINCT a.cartonnumber) AS cartons,
           SUM(a.cartonqty) AS asn_qty, MAX(a.asncreateddt) AS last_asn_dt,
           MAX(CAST(a.wmsenttowm AS int)) AS sent_to_wm
    FROM dbo.pacasncartondata a
    WHERE ISNULL(a.IsDelete, 0) = 0
    GROUP BY a.purchid
),
open_po AS (
    SELECT pt.purchid, pt.recid, pt.documentstate, pt.inventlocationid, pt.orderaccount,
           DATEADD(hour, -7, pt.modifieddatetime) AS po_modified_pt, pt.modifiedby
    FROM dbo.purchtable pt
    WHERE pt.documentstate <> 40            -- not Confirmed
      AND pt.purchstatus = 1                -- Open order
      AND pt.inventlocationid IN ('4901','4905')
      AND ISNULL(pt.IsDelete, 0) = 0
),
remain AS (
    SELECT pl.purchid, SUM(pl.remaininventphysical) AS remain_qty
    FROM dbo.purchline pl
    WHERE pl.purchid IN (SELECT purchid FROM open_po)
      AND ISNULL(pl.IsDelete, 0) = 0 AND pl.isdeleted = 0
    GROUP BY pl.purchid
),
wf AS (          -- newest approval workflow on the PO
    SELECT s.contextrecid, s.originator,
           DATEADD(hour, -7, s.createddatetime) AS submitted_pt,
           ROW_NUMBER() OVER (PARTITION BY s.contextrecid ORDER BY s.createddatetime DESC) AS rn
    FROM dbo.workflowtrackingstatustable s
    WHERE s.contextrecid IN (SELECT recid FROM open_po)
),
wm AS (          -- any WM receipt activity in the window
    SELECT p.pxpon AS purchid, SUM(CAST(p.pxinva AS decimal(18,2))) / 10000 AS wm_rcpt_qty,
           MAX(DATEADD(hour, -7, p.createddatetime)) AS last_wm_rcpt_pt
    FROM dbo.pacwmpixmessage p
    WHERE p.pxtxtp = '606' AND p.pxtxcd = '03'
      AND p.createddatetime >= DATEADD(day, -@days2, SYSUTCDATETIME())
      AND p.pxpon IN (SELECT purchid FROM open_po)
    GROUP BY p.pxpon
)
SELECT o.purchid, o.inventlocationid AS wh, o.orderaccount AS vendor,
       CASE o.documentstate WHEN 0 THEN 'Draft' WHEN 10 THEN 'In review' WHEN 20 THEN 'Approved'
            WHEN 30 THEN 'Rejected' ELSE CAST(o.documentstate AS varchar(10)) END AS po_state,
       r.remain_qty,
       a.asns, a.cartons, a.asn_qty, a.last_asn_dt, a.sent_to_wm,
       w.submitted_pt AS approval_submitted_pt, w.originator AS submitted_by,
       DATEDIFF(day, w.submitted_pt, DATEADD(hour, -7, SYSUTCDATETIME())) AS days_waiting,
       ISNULL(m.wm_rcpt_qty, 0) AS wm_rcpt_qty_last_30d, m.last_wm_rcpt_pt,
       o.po_modified_pt, o.modifiedby
FROM open_po o
JOIN remain r ON r.purchid = o.purchid AND r.remain_qty > 0
JOIN asn a ON a.purchid = o.purchid
LEFT JOIN wf w ON w.contextrecid = o.recid AND w.rn = 1
LEFT JOIN wm m ON m.purchid = o.purchid
ORDER BY CASE WHEN m.wm_rcpt_qty > 0 THEN 0 ELSE 1 END, a.last_asn_dt DESC;
