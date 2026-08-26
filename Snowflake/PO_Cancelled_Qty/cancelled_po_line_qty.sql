/*==============================================================================
  Line-level ORIGINAL ORDERED and CANCELLED units for a cancelled/reduced PO
  Platform : Robling Snowflake (ROBLING_PRD_DB)          Verified: 2026-08-26
================================================================================
  WHY THIS QUERY EXISTS
  ---------------------
  D365 CANNOT answer "what was originally ordered on a cancelled PO":
    * purchline.qtyordered, purchqty, remainder, remainpurch*, remaininvent*
      and the PacSun custom suntafaggpoqty are ALL zeroed on cancel.
    * The matching inventtrans rows are DELETED outright.
    * Synapse carries only purchline / purchtable - there is no
      VendPurchOrderTrans (PO confirmation journal), no purchlinehistory and
      no change-management version table in the feed.

  Robling DOES retain the ordered units on cancelled POs (F_ORD_QTY), but its
  dedicated cancelled-qty columns are DEAD:
      F_CANCLD_QTY, F_CANCLD_CST, F_CANCLD_RTL, F_BACK_ORD_QTY, CANCLD_RSN_ID
      = NULL on all 3,263,211 rows of V_DWH_F_PO_DTL_B.
  Root cause: the staging view DW_STG_V.V_STG_F_PO_DTL_B carries only
  CANCLD_RSN_KEY - no cancelled-qty column exists upstream to feed them.

  => Cancelled units must be DERIVED: F_ORD_QTY - F_RCVD_QTY.

  TRAPS
  -----
  * IP_PO_SRCNUM is the key, NOT PO_NUM (surrogate for 0000-series POs).
  * The view is ROW-VERSIONED. Every PO revision leaves its old lines behind
    stamped with IP_PO_DELETE_DATE; live lines carry the 1900-01-01 sentinel.
    Omit that filter and totals come back several times too high.
  * CANCLD_DT / IP_PO_CANCEL_DATE = the cancel-BY (do-not-ship-after) date,
    NOT the date the PO was cancelled. Same for D365 purchline.paccanceldate.
    The real cancellation timestamp is D365 purchline.modifieddatetime
    where purchstatus = 4.
  * Join the item lookup on ITM_KEY, and filter RCD_CLOSE_FLG = 0 - short SKUs
    are recycled and fan out ~5x without it.
==============================================================================*/

SELECT  d.IP_PO_SRCNUM                        AS PO,
        d.IP_PO_DTL_SEQNUM                    AS SEQ,        -- = D365 purchline.linenumber
        d.IP_PO_SHORT_SKUNUM                  AS SHORT_SKU,  -- = D365 retailvariantid
        i.IP_SKU_DISPLAYNUM                   AS LONG_SKU,
        i.SIZE_ID                             AS SIZE_ID,
        d.IP_PO_STATUS_CODE                   AS STATUS,
        d.F_ORD_QTY                           AS ORIG_ORDERED,
        NVL(d.F_RCVD_QTY,0)                   AS RECEIVED,
        d.F_ORD_QTY - NVL(d.F_RCVD_QTY,0)     AS CANCELLED_UNITS,
        d.IP_PO_SIMPLE_VEND_COST              AS VEND_COST,  -- = D365 purchline.purchprice
        (d.F_ORD_QTY - NVL(d.F_RCVD_QTY,0))
          * NVL(d.IP_PO_SIMPLE_VEND_COST,0)   AS CANCELLED_COST
FROM        ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_DTL_B d
LEFT JOIN   ROBLING_PRD_DB.DW_DWH_V.V_DWH_D_PRD_ITM_LU i
       ON   i.ITM_KEY = d.ITM_KEY
      AND   i.RCD_CLOSE_FLG = 0
WHERE  d.IP_PO_SRCNUM IN ('0000763549','0000767415','0000767598')   -- <<< EDIT
  AND  YEAR(d.IP_PO_DELETE_DATE) = 1900       -- live rows only (row-versioned view)
ORDER BY PO, SEQ;
