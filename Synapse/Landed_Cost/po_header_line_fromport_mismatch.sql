/* ============================================================================
   PO header vs line: ITMFromPort mismatch
   ----------------------------------------------------------------------------
   Every PO whose HEADER carries a from-port (purchtable.itmfromport) where at
   least one live line carries a different value -- blank (the D365 header->line
   copy leak) or a genuinely conflicting port.

   Why it matters: pacApplyLandFactorEstimatesService reads the LINE's port for
   the pacFreightGuidance rate lookup (FromPort x DlvTerm x DlvMode x ItemClass).
   A blank line gets no landed-cost estimate; a different port wins the specific
   rate for the wrong lane. pacFreightGuidance::findSpecificCharges matches
   (FromPort = x OR FromPort = ''), so blank falls through to the wildcard rows.

   Source : d365-synapse-ps-prod-ondemand / dataverse_psprod, company 1001.
            Synapse history starts 2026-04-04 -- this is not all-time.
   Filters: purchtable  ISNULL(IsDelete,0)=0                (CDC tombstone)
            purchline   ISNULL(IsDelete,0)=0 AND isdeleted=0 (D365 keeps deleted
                        lines as rows with isdeleted=1, qty zeroed)
   Notes  : COLLATE DATABASE_DEFAULT on every string compare -- purchtable and
            purchline land on different collations in the serverless pool.
            Flags come from window functions, NOT a CTE self-join: re-joining a
            CTE on multi-column strings silently drops rows in this pool.
   ============================================================================ */

-- ---------------------------------------------------------------- line detail
WITH j AS (
  SELECT h.purchid,
         h.itmfromport                                AS hdr_port,
         ISNULL(h.dlvmode,'')                         AS hdr_mode,
         ISNULL(h.dlvterm,'')                         AS dlvterm,
         h.orderaccount,
         h.purchstatus                                AS hdr_status,   -- 1 open, 2 recd, 3 invoiced, 4 canceled
         h.documentstate                              AS doc_state,
         ISNULL(h.createdby,'')                       AS created_by,
         CAST(h.createddatetime AT TIME ZONE 'UTC'
                                AT TIME ZONE 'Pacific Standard Time' AS date) AS created_pt,
         l.linenumber,
         ISNULL(l.itemid,'')                          AS itemid,
         ISNULL(l.itmfromport,'')                     AS line_port,
         ISNULL(l.dlvmode,'')                         AS line_mode,
         l.qtyordered,
         l.lineamount,
         l.purchstatus                                AS line_status
  FROM purchtable h
  JOIN purchline  l
    ON l.purchid COLLATE DATABASE_DEFAULT = h.purchid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(h.IsDelete,0)=0 AND h.dataareaid='1001'
    AND ISNULL(h.itmfromport,'') <> ''
    AND ISNULL(l.IsDelete,0)=0 AND l.isdeleted=0 AND l.dataareaid='1001'
), f AS (
  SELECT *,
         CASE WHEN line_port COLLATE DATABASE_DEFAULT
                <> hdr_port  COLLATE DATABASE_DEFAULT THEN 1 ELSE 0 END AS mismatch
  FROM j
), w AS (
  SELECT *,
         SUM(mismatch) OVER (PARTITION BY purchid) AS po_bad_lines,
         COUNT(*)      OVER (PARTITION BY purchid) AS po_lines
  FROM f
)
SELECT purchid, hdr_port, hdr_mode, dlvterm, orderaccount, hdr_status, doc_state,
       created_by, created_pt, po_lines, po_bad_lines,
       linenumber, itemid, line_port, line_mode, mismatch,
       CASE WHEN mismatch = 0 THEN ''
            WHEN line_port = '' THEN 'blank on line'
            ELSE 'different value' END AS gap_type,
       qtyordered, lineamount, line_status
FROM w
WHERE po_bad_lines > 0
ORDER BY purchid, linenumber;


-- ------------------------------------------------------------- one row per PO
-- Same population, rolled up: one row per PO. Runnable as-is.
WITH j AS (
  SELECT h.purchid,
         h.itmfromport                                AS hdr_port,
         ISNULL(h.dlvmode,'')                         AS hdr_mode,
         ISNULL(h.dlvterm,'')                         AS dlvterm,
         h.orderaccount,
         h.purchstatus                                AS hdr_status,   -- 1 open, 2 recd, 3 invoiced, 4 canceled
         h.documentstate                              AS doc_state,
         ISNULL(h.createdby,'')                       AS created_by,
         CAST(h.createddatetime AT TIME ZONE 'UTC'
                                AT TIME ZONE 'Pacific Standard Time' AS date) AS created_pt,
         l.linenumber,
         ISNULL(l.itemid,'')                          AS itemid,
         ISNULL(l.itmfromport,'')                     AS line_port,
         ISNULL(l.dlvmode,'')                         AS line_mode,
         l.qtyordered,
         l.lineamount,
         l.purchstatus                                AS line_status
  FROM purchtable h
  JOIN purchline  l
    ON l.purchid COLLATE DATABASE_DEFAULT = h.purchid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(h.IsDelete,0)=0 AND h.dataareaid='1001'
    AND ISNULL(h.itmfromport,'') <> ''
    AND ISNULL(l.IsDelete,0)=0 AND l.isdeleted=0 AND l.dataareaid='1001'
), f AS (
  SELECT *,
         CASE WHEN line_port COLLATE DATABASE_DEFAULT
                <> hdr_port  COLLATE DATABASE_DEFAULT THEN 1 ELSE 0 END AS mismatch
  FROM j
), w AS (
  SELECT *,
         SUM(mismatch) OVER (PARTITION BY purchid) AS po_bad_lines,
         COUNT(*)      OVER (PARTITION BY purchid) AS po_lines
  FROM f
)
SELECT purchid, hdr_port, hdr_mode, dlvterm, orderaccount, hdr_status, created_by,
       MIN(created_pt)     AS created_pt,
       MAX(po_lines)       AS po_lines,
       MAX(po_bad_lines)   AS lines_not_matching,
       SUM(CASE WHEN mismatch=1 AND line_port=''  THEN 1 ELSE 0 END) AS lines_blank,
       SUM(CASE WHEN mismatch=1 AND line_port<>'' THEN 1 ELSE 0 END) AS lines_conflicting,
       SUM(CASE WHEN mismatch=1 THEN qtyordered ELSE 0 END)   AS units_on_bad_lines,
       SUM(CASE WHEN mismatch=1 THEN lineamount ELSE 0 END)   AS amount_on_bad_lines
FROM w
WHERE po_bad_lines > 0
GROUP BY purchid, hdr_port, hdr_mode, dlvterm, orderaccount, hdr_status, created_by
ORDER BY lines_conflicting DESC, lines_not_matching DESC, purchid;
