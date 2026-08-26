/*==============================================================================
  PO REVISION HISTORY - units removed vs the original buy
  Platform : Robling Snowflake (ROBLING_PRD_DB)          Verified: 2026-08-26
================================================================================
  For a PARTIALLY cancelled PO (sizes dropped, quantities cut, size scale
  re-keyed) the units are removed by SUPERSEDING the lines, not by a status
  change. F_CANCLD_QTY is NULL warehouse-wide, so the only surviving record of
  the reduction is the row-version history on V_DWH_F_PO_DTL_B.

  Each distinct IP_PO_DELETE_DATE is one generation of the PO. The live
  generation carries the 1900-01-01 sentinel.

  TRAPS
  -----
  * IP_PO_DTL_SEQNUM is NOT stable across generations - it is a running
    sequence over ALL versions (gen1 = 00101..00601, gen2 = 00701..01001).
    Never diff generation-to-generation by SEQ.
  * ITM_ID is NOT reliably the long SKU - on some rows it is a numeric
    surrogate (e.g. 1091141448). JOIN THE ITEM LOOKUP ON ITM_KEY.
  * Generations are not monotonic in content: a PO can revert to an earlier
    size scale on a LATER date. "Original" = earliest generation.
  * A generation where the ENTIRE size scale is replaced (e.g. 9100-9600 ->
    3200-3800) is a SIZE-SCALE RE-KEY, not a cancellation. Units look
    "removed" and "added" but nothing was actually cancelled. Check SIZE_ID
    before reporting units as cancelled.

  Worked example - PO 0000762585 (validated against D365 purchline):
      gen 2026-07-17  6 lines / 150 u   sizes 9100-9600  (original buy)
      gen 2026-07-29  4 lines / 115 u   sizes 3200-3800
      gen 2026-07-30  6 lines / 151 u   sizes 9100-9600
      live 1900-01-01 4 lines / 115 u   sizes 3200-3800
  => a size-scale re-key that flip-flopped, NOT a 35-unit cancellation.
  D365 purchline holds the SAME 20 line numbers but zeroes qtyordered on the
  16 superseded ones, so it sums to only the live 115.
==============================================================================*/

-- 1) Generation summary: units per PO revision, with the size scale in play
SELECT  d.IP_PO_SRCNUM                                     AS PO,
        TO_CHAR(d.IP_PO_DELETE_DATE,'YYYY-MM-DD')          AS GENERATION,
        CASE WHEN YEAR(d.IP_PO_DELETE_DATE)=1900
             THEN 'LIVE' ELSE 'superseded' END             AS GEN_STATE,
        COUNT(*)                                           AS LINES_,
        SUM(d.F_ORD_QTY)                                   AS ORD_QTY,
        MIN(i.SIZE_ID) || '-' || MAX(i.SIZE_ID)            AS SIZE_RANGE
FROM      ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_DTL_B d
LEFT JOIN ROBLING_PRD_DB.DW_DWH_V.V_DWH_D_PRD_ITM_LU i
       ON i.ITM_KEY = d.ITM_KEY
WHERE   d.IP_PO_SRCNUM IN ('0000762585')                   -- <<< EDIT
GROUP BY 1,2,3
ORDER BY PO, GENERATION;

-- 2) Per-SKU reduction: original (earliest generation) vs live.
--    A PO that was never revised has no superseded rows - it is reported with
--    ORIG_QTY = LIVE_QTY and UNITS_REMOVED = 0 rather than a false negative.
WITH gens AS (
    SELECT  d.IP_PO_SRCNUM, d.ITM_KEY, d.F_ORD_QTY, d.IP_PO_DELETE_DATE,
            i.IP_SKU_DISPLAYNUM AS LONG_SKU, i.SIZE_ID,
            COALESCE(
              MIN(CASE WHEN YEAR(d.IP_PO_DELETE_DATE) <> 1900
                       THEN d.IP_PO_DELETE_DATE END)
                OVER (PARTITION BY d.IP_PO_SRCNUM),
              DATE '1900-01-01')                           AS first_gen
    FROM      ROBLING_PRD_DB.DW_DWH_V.V_DWH_F_PO_DTL_B d
    LEFT JOIN ROBLING_PRD_DB.DW_DWH_V.V_DWH_D_PRD_ITM_LU i
           ON i.ITM_KEY = d.ITM_KEY
    WHERE     d.IP_PO_SRCNUM IN ('0000762585')             -- <<< EDIT
), orig AS (
    SELECT IP_PO_SRCNUM, ITM_KEY, ANY_VALUE(LONG_SKU) LONG_SKU,
           ANY_VALUE(SIZE_ID) SIZE_ID, SUM(F_ORD_QTY) AS ORIG_QTY
    FROM gens WHERE IP_PO_DELETE_DATE = first_gen GROUP BY 1,2
), live AS (
    SELECT IP_PO_SRCNUM, ITM_KEY, ANY_VALUE(LONG_SKU) LONG_SKU,
           ANY_VALUE(SIZE_ID) SIZE_ID, SUM(F_ORD_QTY) AS LIVE_QTY
    FROM gens WHERE YEAR(IP_PO_DELETE_DATE) = 1900 GROUP BY 1,2
)
SELECT  COALESCE(o.IP_PO_SRCNUM, l.IP_PO_SRCNUM)           AS PO,
        COALESCE(o.LONG_SKU,     l.LONG_SKU)               AS LONG_SKU,
        COALESCE(o.SIZE_ID,      l.SIZE_ID)                AS SIZE_ID,
        NVL(o.ORIG_QTY,0)                                  AS ORIG_QTY,
        NVL(l.LIVE_QTY,0)                                  AS LIVE_QTY,
        NVL(o.ORIG_QTY,0) - NVL(l.LIVE_QTY,0)              AS UNITS_REMOVED
FROM      orig o
FULL JOIN live l
       ON o.IP_PO_SRCNUM = l.IP_PO_SRCNUM
      AND o.ITM_KEY      = l.ITM_KEY
ORDER BY PO, SIZE_ID;
