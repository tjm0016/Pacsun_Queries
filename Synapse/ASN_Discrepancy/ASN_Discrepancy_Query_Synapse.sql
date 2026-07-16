-- ============================================================
-- ASN Receipt Discrepancy: WM (PIX) vs D365 (WMSJournalTrans)
-- Platform: Azure Synapse (Serverless SQL / Spark)
-- Timezone: Eastern Time via convert_timezone
-- Window: Rolling 20 days from current_date()
-- ============================================================

WITH pix AS (
    SELECT
        pxpon                                   AS PONumber,
        pxstyl                                  AS WMStyle,
        pxcolr                                  AS WMColor,
        pxszcd                                  AS Size,
        SUM(CAST(pxunrc AS BIGINT)) / 10000     AS WM_Qty
    FROM dw_lnd.lp_pacwmpixmessage
    WHERE date(convert_timezone('UTC', 'America/New_York', createddatetime)) >= dateadd(DAY, -20, current_date())
      AND pxtxtp = '606'
      AND pxtxcd = '03'
    GROUP BY pxpon, pxstyl, pxcolr, pxszcd
),
d365 AS (
    SELECT
        L.inventtransrefid                      AS PONumber,
        L.itemid                                AS Item,
        D.inventcolorid                         AS D365Color,
        D.inventsizeid                          AS Size,
        SUM(L.qty)                              AS D365_Qty
    FROM DW_LND.LP_wmsjournaltable T
    JOIN DW_LND.LP_wmsjournaltrans L
        ON  L.journalid   = T.journalid
        AND L.dataareaid  = T.dataareaid
    JOIN DW_LND.LP_inventdim D
        ON  D.inventdimid = L.inventdimid
        AND D.dataareaid  = L.dataareaid
    WHERE T.dataareaid          = '1001'
      AND T.IsDelete            IS NULL
      AND L.IsDelete            IS NULL
      AND T.posted              = 1
      AND D.inventlocationid    = '4901'
      AND DATE(CONVERT_TIMEZONE('UTC', 'America/New_York', T.posteddatetime)) >= dateadd(DAY, -20, current_date())
    -- NOTE: grouping by date only (not full timestamp) to prevent WM_Qty duplication
    -- when the same PO+Size has receipts posted at different times across the window
    GROUP BY L.inventtransrefid, L.itemid, D.inventcolorid, D.inventsizeid
),
comparison AS (
    SELECT
        COALESCE(p.PONumber, d.PONumber)        AS PONumber,
        d.Item                                  AS Item,
        p.WMStyle                               AS WMStyle,
        p.WMColor                               AS WMColor,
        COALESCE(p.Size, d.Size)                AS Size,
        coalesce(p.WM_Qty,   0)                 AS WM_Qty,
        coalesce(d.D365_Qty, 0)                 AS D365_Qty,
        coalesce(p.WM_Qty, 0) - coalesce(d.D365_Qty, 0) AS Gap_Qty
    FROM pix p
    -- Join on PO + size only (PIX color codes differ from D365 inventcolorid)
    FULL OUTER JOIN d365 d
        ON  d.PONumber = p.PONumber
        AND d.Size     = p.Size
)
SELECT
    PONumber,
    Item,
    (SUBSTRING(ITEM, 1,4) || SUBSTRING(ITEM, 6,5) || SUBSTRING(ITEM, 12,4) || WMCOLOR || SIZE) AS LONGSKU,
    WMStyle,
    WMColor,
    Size,
    WM_Qty,
    D365_Qty,
    Gap_Qty
FROM comparison
WHERE Gap_Qty <> 0
ORDER BY Gap_Qty DESC, PONumber, Size;
