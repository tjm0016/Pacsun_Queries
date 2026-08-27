/*  WM PIX receipt adjustments — Date Error / Prep / Reverse-Undo Receipt / Vendor Error
    -------------------------------------------------------------------------------------
    Finds every PIX transaction where the DC corrected an existing PO receipt.

      type/code   300/01  or  606/02
      action code 08, 26, 27
      reason code (pxrscd) DE, PR, RR, UR, VE

    Reason codes:
      DE = Date Error        PR = Prep (VAS adjustment)   RR = Reverse Receipt
      UR = Undo Receipt      VE = Vendor Error

    Quantity lives in pxinva (÷10,000). DIRECTION comes from pxinat: A = add, S = subtract.
    (pxunsh/pxunrc are zero on these — do not use them here.)

    NOTE: in the data as of 2026-08-18 the 300/01 and 606/02 legs share NO pxtran values,
    so they are independent adjustments, not two halves of one transaction — summing both
    does not double-count. Re-check that assumption before reusing on a new window:
        SELECT COUNT(*) FROM (SELECT pxtran FROM ... WHERE pxtxtp='300'
        INTERSECT SELECT pxtran FROM ... WHERE pxtxtp='606') x;

    pxdcr/pxtcr are WM's iSeries EASTERN clock — not UTC, not Pacific.
    Target: d365-synapse-ps-prod-ondemand / dataverse_psprod_...
    Builds: Code\PIX_Receipt_Adjustments_Report.xlsx
*/

/* ---- 1. rollup by type / code / action / reason ---------------------- */
SELECT pxtxtp AS type, pxtxcd AS code, pxaccd AS action_code, pxrscd AS reason_code,
       CASE pxrscd WHEN 'DE' THEN 'Date Error' WHEN 'PR' THEN 'Prep (VAS adjustment)'
                   WHEN 'RR' THEN 'Reverse Receipt' WHEN 'UR' THEN 'Undo Receipt'
                   WHEN 'VE' THEN 'Vendor Error' END AS reason_desc,
       COUNT(*) AS pix_lines,
       COUNT(DISTINCT pxpon) AS pos,
       SUM(CASE WHEN pxinat = 'A' THEN CAST(pxinva AS bigint) ELSE 0 END)/10000.0 AS units_added,
       SUM(CASE WHEN pxinat = 'S' THEN CAST(pxinva AS bigint) ELSE 0 END)/10000.0 AS units_subtracted,
       SUM(CAST(pxinva AS bigint))/10000.0                                        AS units_gross,
       SUM(CASE WHEN pxinat = 'S' THEN -CAST(pxinva AS bigint)
                ELSE CAST(pxinva AS bigint) END)/10000.0                          AS units_net,
       MIN(pxdcr) AS first_dcr, MAX(pxdcr) AS last_dcr
FROM pacwmpixmessage
WHERE ISNULL(IsDelete,0) = 0
  AND ((pxtxtp = '300' AND pxtxcd = '01') OR (pxtxtp = '606' AND pxtxcd = '02'))
  AND pxaccd IN ('08','26','27')
  AND pxrscd IN ('DE','PR','RR','UR','VE')
GROUP BY pxtxtp, pxtxcd, pxaccd, pxrscd
ORDER BY pxtxtp, pxtxcd, pxaccd, pxrscd;


/* ---- 2. rollup by PO ------------------------------------------------- */
SELECT pxpon AS po,
       COUNT(*) AS pix_lines,
       SUM(CAST(pxinva AS bigint))/10000.0 AS units_gross,
       SUM(CASE WHEN pxinat = 'S' THEN -CAST(pxinva AS bigint)
                ELSE CAST(pxinva AS bigint) END)/10000.0 AS units_net,
       COUNT(DISTINCT pxrscd) AS distinct_reasons,
       MIN(pxdcr) AS first_dcr, MAX(pxdcr) AS last_dcr
FROM pacwmpixmessage
WHERE ISNULL(IsDelete,0) = 0
  AND ((pxtxtp = '300' AND pxtxcd = '01') OR (pxtxtp = '606' AND pxtxcd = '02'))
  AND pxaccd IN ('08','26','27')
  AND pxrscd IN ('DE','PR','RR','UR','VE')
GROUP BY pxpon
ORDER BY units_gross DESC;


/* ---- 3. line-level detail (feeds the Detail tab) --------------------- */
SELECT TRY_CONVERT(date, RIGHT(p.pxdcr,8))       AS wm_date,
       RIGHT(p.pxtcr,6)                          AS wm_time,
       p.pxtxtp AS type, p.pxtxcd AS code, p.pxaccd AS action_code, p.pxrscd AS reason_code,
       p.pxpon AS po,
       p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr AS itemid,
       p.pxszcd AS size, p.pxwhse AS warehouse,
       p.pxinat AS adj_sign,
       CAST(p.pxinva AS bigint)/10000.0          AS units_abs,
       CASE WHEN p.pxinat = 'S' THEN -CAST(p.pxinva AS bigint)/10000.0
            ELSE CAST(p.pxinva AS bigint)/10000.0 END AS units_signed,
       p.pxtran AS pix_tran, p.pxseqn AS pix_seq,
       m.messageid, m.messagestatus,          -- 40 = processed; anything else did not land
       p.pxuser AS wm_user, p.pxcasn AS carton_asn, p.pxvasn AS vendor_asn
FROM pacwmpixmessage p
LEFT JOIN sunintmessage m ON m.recid = p.message AND ISNULL(m.IsDelete,0) = 0
WHERE ISNULL(p.IsDelete,0) = 0
  AND ((p.pxtxtp = '300' AND p.pxtxcd = '01') OR (p.pxtxtp = '606' AND p.pxtxcd = '02'))
  AND p.pxaccd IN ('08','26','27')
  AND p.pxrscd IN ('DE','PR','RR','UR','VE')
ORDER BY wm_date, p.pxpon;
