/* ============================================================================
   VI Date -- the LIVE source is the Robling PO HEADER, not a VI_DATES table
   ----------------------------------------------------------------------------
   Connection : SnowFlake (ROBLING_PRD_DB)
   Verified   : 2026-09-04

   ANSWER: VI Date = ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_HDR_B.IP_ANTCP_ARRIVAL_DT
   Proven 663/663 EXACT MATCH against D365 pacpotrackingdata.eta (all 731 live
   rows), zero disagreements -- same upstream feed, far better coverage.

   Coverage, open POs with a VI date:
     Snowflake header  2,005   (6,762 including closed/invoiced POs)
     Synapse pacpotrackingdata 731
     -> 1,342 open POs Snowflake has that Synapse does NOT.
   Neither is a superset: 68 of the Synapse 731 have no header row at all.

   Corroboration that this header is what IA reads: IP_PO_HANDLING_TYPE on the
   same row reproduces IA's Handling Type column 30/30 (NEW FLOW / ECOMM /
   FLOOR09B) on a hand-checked PO list.

   *** THE TABLES THAT LOOK RIGHT ARE ALL DEAD -- do not use them: ***
     DW_PACSUN.F_VI_DATES / F_VI_DATES_V  2,026 rows, all Feb-Apr 2025.
        ANTCP_ARRIVAL_DT == IP_PO_VDATE and IP_PO_VPO == IP_PO_SRCNUM on every
        row -- a one-off backfill written to patch the header, not a feed.
     DW_LND.LP_VI_DATES     1,622 rows (VPO + VDATE text), VDATE stops 20260507.
     DW_PACSUN.LP_VI_DATES  2,036 rows, 2025 only.
     ROBLING_IA_SHARED_DB   has NO VI object at all (45 views, none with a VI
        or arrival date) -- IA does not read VI Date out of the IA share.

   LIMITS
     * NO HISTORY. RCD_UPD_TS is one nightly stamp for the whole table, so you
       cannot see when a VI date was revised -- and it IS revised: 9 POs
       captured off IA's screen on 8/14 had all moved +1 to +21 days by 9/4,
       every one of them pushed LATER. Snapshot daily if you need the trend.
     * DW_STG_V.V_STG_F_PO_HDR_B_INTRADAY carries IP_ANTCP_ARRIVAL_DT and
       IP_PO_HANDLING_TYPE but is DRAINED between loads (0 rows when checked).
     * The 1900-01-01 sentinel means "no VI date", not NULL. And beware:
       EXTRACT/YEAR() on this column throws "does not support NULL argument
       type" on the intraday view -- compare with > '1901-01-01' instead.
     * Filter YEAR(IP_PO_DELETE_DATE)=1900 -- the header is row-versioned too.
   ============================================================================ */

/* ---- VI date + handling type for a PO list ----------------------------- */
SELECT IP_PO_SRCNUM,
       CASE WHEN IP_ANTCP_ARRIVAL_DT > '1901-01-01' THEN IP_ANTCP_ARRIVAL_DT END AS vi_date,
       IP_PO_HANDLING_TYPE,
       IP_PO_STATUS_CODE,
       ASN_RCVD_DT,
       IP_PO_SHIP_NO_EARLIER_DATE,
       IP_PO_SHIP_NO_LATER_DATE,
       RCD_UPD_TS
FROM ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_HDR_B
WHERE YEAR(IP_PO_DELETE_DATE) = 1900
  AND IP_PO_SRCNUM IN ('0001307126','0000767435','0001372336')
ORDER BY IP_PO_SRCNUM;

/* ---- Coverage: how much better is this than pacpotrackingdata? --------- */
SELECT COUNT(*)                                                        AS live_headers,
       SUM(CASE WHEN IP_ANTCP_ARRIVAL_DT > '1901-01-01' THEN 1 ELSE 0 END) AS with_vi_date,
       SUM(CASE WHEN IP_PO_STATUS_CODE = 'Open order' THEN 1 ELSE 0 END)   AS open_pos,
       SUM(CASE WHEN IP_PO_STATUS_CODE = 'Open order'
                 AND IP_ANTCP_ARRIVAL_DT > '1901-01-01' THEN 1 ELSE 0 END) AS open_with_vi_date,
       COUNT(DISTINCT IP_ANTCP_ARRIVAL_DT)                             AS distinct_dates,
       MIN(CASE WHEN IP_ANTCP_ARRIVAL_DT > '1901-01-01' THEN IP_ANTCP_ARRIVAL_DT END) AS vi_min,
       MAX(IP_ANTCP_ARRIVAL_DT)                                        AS vi_max
FROM ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_HDR_B
WHERE YEAR(IP_PO_DELETE_DATE) = 1900;

/* ---- The open POs with a VI date that Synapse cannot see ---------------- */
/* Feed the padded purchids from Synapse
   (SELECT purchid FROM pacpotrackingdata WHERE IsDelete IS NULL AND eta > '1900-01-02')
   into the NOT IN list to reproduce the 1,342-PO gap.                       */
SELECT IP_PO_SRCNUM, IP_ANTCP_ARRIVAL_DT AS vi_date, IP_PO_HANDLING_TYPE
FROM ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_HDR_B
WHERE YEAR(IP_PO_DELETE_DATE) = 1900
  AND IP_PO_STATUS_CODE = 'Open order'
  AND IP_ANTCP_ARRIVAL_DT > '1901-01-01'
  AND IP_PO_SRCNUM NOT IN ('0000759613','0000759614')   -- <- the Synapse live set
ORDER BY vi_date;

/* ---- The dead tables, for the record ----------------------------------- */
SELECT 'DW_PACSUN.F_VI_DATES' AS obj, COUNT(*) AS rows_all,
       MIN(IP_PO_VDATE) AS oldest, MAX(IP_PO_VDATE) AS newest
FROM ROBLING_PRD_DB.DW_PACSUN.F_VI_DATES
UNION ALL
SELECT 'DW_LND.LP_VI_DATES', COUNT(*), MIN(VDATE), MAX(VDATE)
FROM ROBLING_PRD_DB.DW_LND.LP_VI_DATES
UNION ALL
SELECT 'DW_PACSUN.LP_VI_DATES', COUNT(*), MIN(VDATE), MAX(VDATE)
FROM ROBLING_PRD_DB.DW_PACSUN.LP_VI_DATES;
