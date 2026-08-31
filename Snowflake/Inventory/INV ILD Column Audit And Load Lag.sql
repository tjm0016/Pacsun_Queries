/* Health check for ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_F_INV_ILD_B.
   This view is a TYPE-2 SCD: one row per (item, location) value-run, DAY_KEY = first day of the
   run, END_DAY_KEY = last day (INCLUSIVE) or 9999-12-31 while open. A "today" row does not exist -
   the predicate DAY_KEY <= D AND END_DAY_KEY >= D just re-serves the open run, so a query for
   today silently returns a stale measurement. Check MAX(DAY_KEY) before trusting a recent date.

   Column sourcing (established 2026-08-31 on style 0193-52280-0295-001):
     F_OH_QTY          = D365 physical on-hand (Active + Lock_Code). Tied 5/5 sizes at 4901 on 8/26.
     IP_INV_AVAIL_UNTS = the WM "All Inventory by SKU" SFTP extract, unlocked units only,
                         Robling day D = the file stamped (D+1) at 07:00Z.
   The two columns are populated on DIFFERENT warehouses - see query 2. */

/* 1. How many days after the business day does a row actually land? */
SELECT l.IP_STORE_NUM AS WH,
       DATEDIFF('day', i.DAY_KEY,
                CONVERT_TIMEZONE('America/Los_Angeles', i.RCD_UPD_TS)::DATE) AS LOAD_LAG_DAYS,
       COUNT(*) AS ROWS_
FROM ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_F_INV_ILD_B i
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_ORG_LOC_LU l ON i.LOC_KEY = l.LOC_KEY
WHERE l.IP_STORE_NUM IN (4901,4905)
  AND i.DAY_KEY BETWEEN '2026-08-20' AND '2026-08-30'
GROUP BY 1,2 ORDER BY 1,2;

/* 2. Newest business day actually present, and which unit columns are populated, per warehouse.
      Expect AVAIL ~100% at 4901 and near-zero at 4905 - they are fed by different pipelines. */
SELECT l.IP_STORE_NUM AS WH,
       TO_CHAR(MAX(i.DAY_KEY),'YYYY-MM-DD') AS MAX_DAY_KEY,
       COUNT(*)                      AS OPEN_ROWS,
       COUNT(i.IP_INV_AVAIL_UNTS)    AS AVAIL_POPULATED,
       COUNT(i.F_OH_QTY)             AS OH_POPULATED
FROM ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_F_INV_ILD_B i
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_ORG_LOC_LU l ON i.LOC_KEY = l.LOC_KEY
WHERE l.IP_STORE_NUM IN (4901,4905) AND i.END_DAY_KEY = '9999-12-31'
GROUP BY 1 ORDER BY 1;

/* 3. Every unit column + the load timestamp, raw rows, for one style-color. Run this before
      trusting any single number - it exposes the run boundaries and the backfill lag. */
SELECT l.IP_STORE_NUM AS WH, p.SIZE_ID AS SZ,
       TO_CHAR(i.DAY_KEY,'YYYY-MM-DD')     AS DAY_KEY,
       TO_CHAR(i.END_DAY_KEY,'YYYY-MM-DD') AS END_DAY_KEY,
       i.F_OH_QTY, i.F_IT_QTY, i.F_TSF_RESV_QTY, i.F_CUS_RESV_QTY,
       i.F_NON_SELLABLE_QTY, i.IP_INV_DC_TR_UNTS,
       i.IP_INV_ALLOC_UNTS, i.IP_INV_AVAIL_UNTS,
       TO_CHAR(CONVERT_TIMEZONE('America/Los_Angeles', i.RCD_UPD_TS),'YYYY-MM-DD HH24:MI') AS LOADED_PT
FROM ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_F_INV_ILD_B i
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_PRD_ITM_LU p ON i.ITM_KEY = p.ITM_KEY
JOIN ROBLING_IA_SHARED_DB.DW_SHARED.V_DWH_D_ORG_LOC_LU l ON i.LOC_KEY = l.LOC_KEY
WHERE SUBSTR(p.IP_SKU_DISPLAYNUM,1,16) = '0193522800295001'
  AND l.IP_STORE_NUM IN (4901,4905)
  AND i.END_DAY_KEY >= '2026-08-26'
ORDER BY 1,2,3;
