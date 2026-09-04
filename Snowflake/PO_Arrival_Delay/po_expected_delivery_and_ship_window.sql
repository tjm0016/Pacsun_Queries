/* ============================================================================
   Robling PO date anchors for an arrival-delay review
   ----------------------------------------------------------------------------
   Connection : SnowFlake (ROBLING_PRD_DB)
   Pairs with : Synapse/PO_Arrival_Delay/po_appointment_vi_expected_receipt_delay.sql

   Why Snowflake: IP_PO_EXP_DEL_DATE is 100% populated on open lines, and the
   vendor ship window IP_PO_SHIP_NO_EARLIER_DATE / IP_PO_SHIP_NO_LATER_DATE has
   no D365 equivalent -- it is what tells you whether the vendor shipped inside
   its own window before you blame the DC for the delay.

   MUST-DOs
     * Join on IP_PO_SRCNUM (zero-padded 10-char), NEVER PO_NUM -- PO_NUM is a
       surrogate for the 0000-series POs and returns zero rows.
     * Filter YEAR(IP_PO_DELETE_DATE) = 1900 -- the view is row-versioned and a
       plain SUM over all generations can be several times too high.
   TRAPS
     * IP_PO_CANCEL_DATE is a cancel-BY / do-not-ship-after date, not a
       cancellation timestamp. It is populated on healthy open POs too.
     * IP_PO_ORIG_EXP_ISO_DATE and IP_PO_SHIP_NO_LATER_DATE come back as the
       1900 sentinel on the 0001-series (MAO) POs.
     * F_RCVD_QTY / IP_PO_BALORDR_UNTS lag D365 by up to a day.
     * ASN_FLG = 'N' with a zero ASN_CODE means no ASN exists in either system --
       a genuinely un-shipped PO, not a feed gap.
   ============================================================================ */

SELECT IP_PO_SRCNUM,
       MIN(IP_PO_CREATE_DATE)            AS po_create,
       MIN(IP_PO_SHIP_NO_EARLIER_DATE)   AS ship_no_earlier,
       MIN(IP_PO_SHIP_ISO_DATE)          AS ship_iso,
       MIN(IP_PO_SHIP_NO_LATER_DATE)     AS ship_no_later,
       MIN(IP_PO_CANCEL_DATE)            AS cancel_by,
       MIN(IP_PO_EXP_DEL_DATE)           AS expected_receipt,
       MAX(IP_PO_ASN_FLG)                AS asn_flg,
       MAX(IP_PO_ASN_CODE)               AS asn_code,   -- 30 char; RIGHT(...,20) = D365 pacasnid
       SUM(F_ORD_QTY)                    AS ordered,
       SUM(F_RCVD_QTY)                   AS received,
       SUM(IP_PO_BALORDR_UNTS)           AS open_units,
       MAX(IP_PO_STATUS_CODE)            AS status,
       MAX(RCD_UPD_TS)                   AS row_updated
FROM ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_DTL_B
WHERE IP_PO_SRCNUM IN ('0000765313','0001307126')
  AND YEAR(IP_PO_DELETE_DATE) = 1900          -- live generation only
GROUP BY IP_PO_SRCNUM
ORDER BY IP_PO_SRCNUM;
