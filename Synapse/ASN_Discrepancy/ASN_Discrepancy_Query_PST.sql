-- ============================================================
-- ASN Receipt Discrepancy: WM (PIX) vs D365 (WMSJournalTrans)
-- Change @ReportDate to the date you want to investigate (PST)
-- ============================================================

DECLARE @ReportDate DATE = '2026-06-12';   -- <-- CHANGE THIS DATE

WITH pix AS (
    SELECT
        pxpon                                   AS PONumber,
        pxstyl                                  AS WMStyle,
        pxcolr                                  AS WMColor,
        pxszcd                                  AS Size,
        SUM(CAST(pxunrc AS BIGINT)) / 10000     AS WM_Qty
    FROM dbo.pacwmpixmessage
    WHERE CAST(createddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = @ReportDate
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
    FROM dbo.wmsjournaltable T
    JOIN dbo.wmsjournaltrans L
        ON  L.journalid   = T.journalid
        AND L.dataareaid  = T.dataareaid
    JOIN dbo.inventdim D
        ON  D.inventdimid = L.inventdimid
        AND D.dataareaid  = L.dataareaid
    WHERE T.dataareaid          = '1001'
      AND T.IsDelete            IS NULL
      AND L.IsDelete            IS NULL
      AND T.posted              = 1
      AND D.inventlocationid    = '4901'
      AND CAST(T.posteddatetime AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE) = @ReportDate
    GROUP BY L.inventtransrefid, L.itemid, D.inventcolorid, D.inventsizeid
),
comparison AS (
    SELECT
        COALESCE(p.PONumber, d.PONumber)    AS PONumber,
        d.Item                              AS Item,
        p.WMStyle                           AS WMStyle,
        p.WMColor                           AS WMColor,
        COALESCE(p.Size, d.Size)            AS Size,
        ISNULL(p.WM_Qty,   0)              AS WM_Qty,
        ISNULL(d.D365_Qty, 0)              AS D365_Qty,
        ISNULL(p.WM_Qty, 0) - ISNULL(d.D365_Qty, 0) AS Gap_Qty
    FROM pix p
    -- Join on PO + size only (PIX color codes differ from D365 inventcolorid)
    FULL OUTER JOIN d365 d
        ON  d.PONumber = p.PONumber
        AND d.Size     = p.Size
)
SELECT
    @ReportDate AS ReportDate,
    PONumber,
    Item,
    WMStyle,
    WMColor,
    Size,
    WM_Qty,
    D365_Qty,
    Gap_Qty
FROM comparison
WHERE Gap_Qty <> 0
ORDER BY Gap_Qty DESC, PONumber, Size;

-- ============================================================
-- Summary totals by PO (uncomment to use)
-- ============================================================
-- SELECT
--     @ReportDate AS ReportDate,
--     PONumber,
--     Item,
--     WMStyle,
--     WMColor,
--     SUM(WM_Qty)   AS Total_WM_Qty,
--     SUM(D365_Qty) AS Total_D365_Qty,
--     SUM(Gap_Qty)  AS Total_Gap
-- FROM comparison
-- WHERE Gap_Qty <> 0
-- GROUP BY PONumber, Item, WMStyle, WMColor
-- ORDER BY Total_Gap DESC;
