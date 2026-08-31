/* Robling daily inventory (V_DWH_F_INV_ILD_B) by size for one style-color at the two DCs.
   Parameterise the 16-char long-SKU prefix = class(4)+vendorstyle(5)+style(4)+color(3).
   NOTE: END_DAY_KEY is INCLUSIVE - use DAY_KEY <= D AND END_DAY_KEY >= D, never END_DAY_KEY > D.
   NOTE: for 4901 the IP_INV_AVAIL_UNTS column is fed from the WM "All Inventory by SKU"
         SFTP extract at 07:00Z (midnight PT). F_OH_QTY at 4901 does NOT track and can sit
         frozen for days - do not use it. 4905 is the reliable warehouse in this view. */
WITH d AS (SELECT DAY_KEY AS D
           FROM ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_TIM_DAY_LU
           WHERE DAY_KEY BETWEEN '2026-08-27' AND '2026-08-31')
SELECT TO_CHAR(d.D,'YYYY-MM-DD')      AS D,
       l.IP_STORE_NUM                 AS WH,
       p.SIZE_ID                      AS SZ,
       SUM(NVL(i.F_OH_QTY,0))             AS OH,
       SUM(NVL(i.IP_INV_AVAIL_UNTS,0))    AS AVAIL,
       SUM(NVL(i.IP_INV_ALLOC_UNTS,0))    AS ALLOC,
       SUM(NVL(i.F_IT_QTY,0))             AS INTRANSIT,
       SUM(NVL(i.F_NON_SELLABLE_QTY,0))   AS NONSELL
FROM d
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_F_INV_ILD_B i
  ON i.DAY_KEY <= d.D AND i.END_DAY_KEY >= d.D
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_PRD_ITM_LU p
  ON i.ITM_KEY = p.ITM_KEY
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_ORG_LOC_LU l
  ON i.LOC_KEY = l.LOC_KEY
WHERE SUBSTR(p.IP_SKU_DISPLAYNUM,1,16) = '0193522800295001'
  AND l.IP_STORE_NUM IN (4901,4905)
GROUP BY d.D, l.IP_STORE_NUM, p.SIZE_ID
ORDER BY 2,3,1;

/* Size / description roster for the same style-color. RCD_CLOSE_FLG = 0 keeps IP_SHORT_SKU unique. */
SELECT DISTINCT p.IP_SKU_DISPLAYNUM AS LONGSKU, p.IP_SHORT_SKU AS SHORTSKU,
       p.SIZE_ID, p.COLOR_ID, p.CLS_ID, p.DPT_ID, p.ITM_DESC, p.RCD_CLOSE_FLG
FROM ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_PRD_ITM_LU p
WHERE SUBSTR(p.IP_SKU_DISPLAYNUM,1,16) = '0193522800295001'
ORDER BY 3;
