/* ============================================================================
   SECTION 2 -- open FOB PO lines carrying NO freight charge, reason-coded.
   ----------------------------------------------------------------------------
   Section 1 asks "is the class in the guidance table". This asks the question
   that actually has money behind it: did the line end up with an OCEAN_FRT or
   AIR_FRT charge at all? Ground truth is markuptrans, not a simulation of the
   lookup -- markuptrans is where the charge really lands.

   Scope matches the X++: purchline.purchstatus = 1 (Backorder) and the LINE's
   own dlvterm = 'FOB'. pacApplyLandFactorEstimatesService only touches
   Backorder lines and findSpecificCharges reads _purchLine.DlvTerm / .DlvMode /
   .ITMFromPort -- never the header.

   Two-day grace period: applying land factors is a MANUAL button on the
   PurchTable form. Measured over 8,845 open FOB lines created since 2026-07-01,
   90.4% got their first freight charge the same calendar day and 5.1% the next,
   so alerting on anything younger than 2 days is ~10% false positives on day
   one. Lines younger than that are held back, not lost -- they surface once
   they age in.

   Reason codes, in priority order (2026-09-21 volumes):
     PORT+MODE BLANK   28 lines /   9 POs /     $4,416.72
     PORT BLANK       503 lines / 110 POs /   $101,787.41
     MODE BLANK        38 lines /  15 POs /   $101,186.07
     NO RATE FOR LANE  93 lines /  24 POs /    $20,884.21   <- guidance gap
     ESTIMATE NOT RUN 547 lines / 130 POs / $1,436,775.57   <- the real money
   Total 1,209 lines / 288 POs / $1,665,049.98.

   "NO RATE FOR LANE" emulates findSpecificCharges: a NULL guidance value is a
   wildcard, so the EXISTS below accepts NULL on itemclass / fromport / dlvmode /
   dlvterm. Note wildcards in this table are NULL, never '' -- testing = '' finds
   nothing and every wildcard row silently vanishes.
   ============================================================================ */
WITH l AS (
    SELECT
        pl.purchid, pl.linenumber, pl.recid, pl.itemid, pl.dataareaid,
        ISNULL(it.suntafclassvalue,'')  AS item_class,
        ISNULL(pl.itmfromport,'')       AS line_port,
        ISNULL(pl.dlvmode,'')           AS line_mode,
        ISNULL(pl.dlvterm,'')           AS line_term,
        ISNULL(pl.qtyordered,0)         AS qtyordered,
        ISNULL(pl.lineamount,0)         AS lineamount,
        pl.createddatetime,
        h.orderaccount, h.purchname, h.deliverydate, ISNULL(h.createdby,'') AS created_by
    FROM dbo.purchline pl
    JOIN dbo.inventtable it
      ON it.itemid     COLLATE DATABASE_DEFAULT = pl.itemid     COLLATE DATABASE_DEFAULT
     AND it.dataareaid COLLATE DATABASE_DEFAULT = pl.dataareaid COLLATE DATABASE_DEFAULT
     AND ISNULL(it.IsDelete,0) = 0
    LEFT JOIN dbo.purchtable h
      ON h.purchid    COLLATE DATABASE_DEFAULT = pl.purchid    COLLATE DATABASE_DEFAULT
     AND h.dataareaid COLLATE DATABASE_DEFAULT = pl.dataareaid COLLATE DATABASE_DEFAULT
     AND ISNULL(h.IsDelete,0) = 0
    WHERE ISNULL(pl.IsDelete,0) = 0
      AND pl.isdeleted = 0
      AND pl.dataareaid COLLATE DATABASE_DEFAULT = '1001'
      AND pl.purchstatus = 1
      AND pl.dlvterm COLLATE DATABASE_DEFAULT = 'FOB'
      AND DATEDIFF(day, pl.createddatetime, GETUTCDATE()) >= 2   -- manual-button grace
      /* Drop the ENTIRE PO if ANY line has been received or invoiced -- Tyler
         2026-09-21. Partially received POs are off the report completely. */
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.purchline x
            WHERE x.purchid    COLLATE DATABASE_DEFAULT = pl.purchid    COLLATE DATABASE_DEFAULT
              AND x.dataareaid COLLATE DATABASE_DEFAULT = pl.dataareaid COLLATE DATABASE_DEFAULT
              AND ISNULL(x.IsDelete,0) = 0
              AND x.isdeleted = 0
              AND x.purchstatus IN (2, 3)   -- 2 Received, 3 Invoiced
          )
), nofrt AS (
    SELECT l.*,
           CASE WHEN EXISTS (
                SELECT 1 FROM dbo.pacfreightguidance g
                WHERE ISNULL(g.IsDelete,0) = 0
                  AND g.dataareaid COLLATE DATABASE_DEFAULT = '1001'
                  AND g.markupcode COLLATE DATABASE_DEFAULT IN ('OCEAN_FRT','AIR_FRT')
                  AND (g.itemclass IS NULL OR g.itemclass COLLATE DATABASE_DEFAULT = l.item_class COLLATE DATABASE_DEFAULT)
                  AND (g.fromport  IS NULL OR g.fromport  COLLATE DATABASE_DEFAULT = l.line_port  COLLATE DATABASE_DEFAULT)
                  AND (g.dlvmode   IS NULL OR g.dlvmode   COLLATE DATABASE_DEFAULT = l.line_mode  COLLATE DATABASE_DEFAULT)
                  AND (g.dlvterm   IS NULL OR g.dlvterm   COLLATE DATABASE_DEFAULT = l.line_term  COLLATE DATABASE_DEFAULT)
           ) THEN 1 ELSE 0 END AS lane_has_rate
    FROM l
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.markuptrans m
        WHERE ISNULL(m.IsDelete,0) = 0
          AND m.transrecid = l.recid
          AND m.markupcode COLLATE DATABASE_DEFAULT IN ('OCEAN_FRT','AIR_FRT'))
), coded AS (
    SELECT *,
        CASE WHEN line_port = '' AND line_mode = '' THEN 'PORT+MODE BLANK'
             WHEN line_port = ''                    THEN 'PORT BLANK'
             WHEN line_mode = ''                    THEN 'MODE BLANK'
             WHEN item_class = ''                   THEN 'ITEM HAS NO CLASS'
             WHEN lane_has_rate = 0                 THEN 'NO RATE FOR LANE'
             ELSE 'ESTIMATE NOT RUN' END AS reason
    FROM nofrt
)
SELECT
    c.purchid                                                   AS PO,
    c.orderaccount                                              AS Vendor_Account,
    COALESCE(NULLIF(dp.name,''), NULLIF(c.purchname,''))        AS Vendor_Name,
    STUFF(
        CASE WHEN SUM(CASE WHEN c.reason='PORT+MODE BLANK'   THEN 1 ELSE 0 END)>0 THEN ', PORT+MODE BLANK'   ELSE '' END +
        CASE WHEN SUM(CASE WHEN c.reason='PORT BLANK'        THEN 1 ELSE 0 END)>0 THEN ', PORT BLANK'        ELSE '' END +
        CASE WHEN SUM(CASE WHEN c.reason='MODE BLANK'        THEN 1 ELSE 0 END)>0 THEN ', MODE BLANK'        ELSE '' END +
        CASE WHEN SUM(CASE WHEN c.reason='ITEM HAS NO CLASS' THEN 1 ELSE 0 END)>0 THEN ', ITEM HAS NO CLASS' ELSE '' END +
        CASE WHEN SUM(CASE WHEN c.reason='NO RATE FOR LANE'  THEN 1 ELSE 0 END)>0 THEN ', NO RATE FOR LANE'  ELSE '' END +
        CASE WHEN SUM(CASE WHEN c.reason='ESTIMATE NOT RUN'  THEN 1 ELSE 0 END)>0 THEN ', ESTIMATE NOT RUN'  ELSE '' END,
        1, 2, '')                                               AS Reason,
    COUNT(*)                                                    AS Lines_No_Freight,
    CAST(SUM(c.qtyordered) AS int)                              AS Units,
    CAST(SUM(c.lineamount) AS decimal(18,2))                    AS Amount_At_Risk,
    MAX(NULLIF(c.line_port,''))                                 AS Line_From_Port,
    MAX(NULLIF(c.line_mode,''))                                 AS Line_Mode,
    CONVERT(varchar(10), MIN(c.deliverydate), 101)              AS Delivery_Date,
    DATEDIFF(day, CAST(GETUTCDATE() AS date), MIN(c.deliverydate)) AS Days_To_Delivery,
    c.created_by                                                AS Buyer,
    c.dataareaid                                                AS Company
FROM coded c
LEFT JOIN dbo.vendtable vt
       ON vt.accountnum COLLATE DATABASE_DEFAULT = c.orderaccount COLLATE DATABASE_DEFAULT
      AND vt.dataareaid COLLATE DATABASE_DEFAULT = c.dataareaid   COLLATE DATABASE_DEFAULT
      AND ISNULL(vt.IsDelete,0) = 0
LEFT JOIN dbo.dirpartytable dp ON dp.recid = vt.party
GROUP BY c.purchid, c.orderaccount, c.purchname, c.created_by, c.dataareaid, dp.name
/* biggest dollars first - this list is worked top-down, not chronologically */
ORDER BY SUM(c.lineamount) DESC, c.purchid;
