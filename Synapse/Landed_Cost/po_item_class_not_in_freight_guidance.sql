/* ============================================================================
   D365_PO_Item_Class_Not_In_Freight_Guidance  --  exception-only email report
   ----------------------------------------------------------------------------
   Fires ONLY when a purchase-order line carries an item whose CLASS has no row
   in pacfreightguidance. Zero rows -> Check_for_rows goes false -> no email.

   WHY A MISSING CLASS COSTS REAL MONEY
   pacApplyLandFactorEstimatesService loops per distinct primary MarkupCode and
   calls pacFreightGuidance::findSpecificCharges. That method treats a BLANK
   guidance value as a wildcard (ItemClass == _itemClass || ItemClass == ''),
   so you would expect a missing class to fall back to a wildcard row.
   It does not for freight: of the 7,157 live guidance rows, 29 are wildcards
   (itemclass NULL) and **not one of them carries OCEAN_FRT or AIR_FRT** -- the
   wildcards are IF_ABS / OVH-LOAD_ABS only. So a class absent from this table
   genuinely loses its ocean/air freight charge. Verified 2026-09-21:
       live_rows 7,157 | distinct classes 198 | freight rows 7,128
       wildcard rows 29 | wildcard rows carrying freight 0

   SCOPE -- read every field off the LINE, never the header
   pacApplyLandFactorEstimatesService filters `purchLine.PurchStatus ==
   PurchStatus::Backorder` and findSpecificCharges reads _purchLine.DlvTerm /
   .DlvMode / .ITMFromPort. Using purchtable.purchstatus instead pulls in 7,547
   lines / $20.6M that are already received, invoiced or cancelled at line level
   and will never be priced again.

   Filters: purchline  ISNULL(IsDelete,0)=0 AND isdeleted=0
            inventtable ISNULL(IsDelete,0)=0
            pacfreightguidance ISNULL(IsDelete,0)=0
            -- NOTE: pacfreightguidance has NO `isdeleted` column, only
            -- `IsDelete`. Adding one throws "Invalid column name".
   Notes  : COLLATE DATABASE_DEFAULT on every string compare.
            INNER JOIN to inventtable is deliberate: every live PO line that
            fails to resolve an item has a BLANK itemid (non-stocked
            procurement-category spend) -- there is not one live 1001 line
            carrying a real itemid absent from inventtable. Those are a
            separate data-quality problem, not a class gap.
            suntafclass is NOT used as the class master -- that table stopped
            syncing into Synapse on 2026-04-02 and is ~6 months stale.

   HEALTH GUARD (the UNION ALL branch)
   pacfreightguidance is hand-maintained and bulk-reloaded: on 2026-09-11
   MAberle deleted 14,273 rows and inserted 7,151 in a single pass. A run that
   lands mid-reload would see a thin or empty table and flag EVERY class on
   EVERY PO. So the class rows are only emitted while the table looks sane, and
   if it does not, the report emits one loud row saying so instead.

   Sized 2026-09-21: 4 PO lines across 3 classes (0263, 0260, 0271), all
   created 05/26/2026, all non-FOB, $80.00 total. It would have fired once in
   the 5.5-month Synapse window. The freight-bearing FOB population has ZERO
   class gaps -- see README for what IS leaking instead.
   ============================================================================ */
WITH health AS (
    SELECT
        COUNT(*)                                                    AS live_rows,
        COUNT(DISTINCT g.itemclass)                                 AS distinct_classes,
        SUM(CASE WHEN g.markupcode COLLATE DATABASE_DEFAULT
                      IN ('OCEAN_FRT','AIR_FRT') THEN 1 ELSE 0 END) AS freight_rows
    FROM dbo.pacfreightguidance g
    WHERE ISNULL(g.IsDelete,0) = 0
      AND g.dataareaid COLLATE DATABASE_DEFAULT = '1001'
), gaps AS (
    SELECT
        pl.purchid,
        pl.linenumber,
        pl.itemid,
        it.suntafclassvalue                     AS item_class,
        pl.dataareaid,
        ISNULL(pl.dlvterm,'')                   AS line_term,
        ISNULL(pl.dlvmode,'')                   AS line_mode,
        ISNULL(pl.itmfromport,'')               AS line_port,
        ISNULL(pl.qtyordered,0)                 AS qtyordered,
        ISNULL(pl.lineamount,0)                 AS lineamount,
        pl.createddatetime,
        h.orderaccount,
        h.purchname
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
      AND pl.purchstatus = 1                    -- Backorder, read off the LINE
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
      AND ISNULL(it.suntafclassvalue,'') <> ''  -- blank class is a different problem
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.pacfreightguidance g
            WHERE ISNULL(g.IsDelete,0) = 0
              AND g.dataareaid COLLATE DATABASE_DEFAULT = '1001'
              AND g.itemclass COLLATE DATABASE_DEFAULT
                = it.suntafclassvalue COLLATE DATABASE_DEFAULT
          )
      /* ---- Suppressed 2026-09-21 on Tyler's call. These are dropship classes on
              4 EDIKTED LLC lines created 05/26/2026, blank delivery terms, $80.00
              total. They are a permanent state, not an event, so leaving them in
              would email the same 4 rows every morning forever and defeat the
              point of an exception-only alert. A genuinely NEW unmapped class
              still fires. Remove a code from this list to un-suppress it. ---- */
      AND it.suntafclassvalue COLLATE DATABASE_DEFAULT NOT IN (
            '0260',   -- dropship, EDIKTED LLC  PO 0001332822
            '0263',   -- dropship, EDIKTED LLC  POs 0001332448 / 0001332672
            '0271'    -- dropship, EDIKTED LLC  PO 0001332236
          )
)
SELECT
    CASE WHEN g.line_term COLLATE DATABASE_DEFAULT = 'FOB'
         THEN 'CLASS MISSING - FOB (loses freight)'
         ELSE 'CLASS MISSING' END                              AS Alert,
    g.purchid                                                  AS PO,
    CAST(g.linenumber AS int)                                  AS Line,
    g.itemid                                                   AS Item,
    g.item_class                                               AS Item_Class,
    g.orderaccount                                             AS Vendor_Account,
    COALESCE(NULLIF(dp.name,''), NULLIF(g.purchname,''))       AS Vendor_Name,
    NULLIF(g.line_term,'')                                     AS Line_Terms,
    NULLIF(g.line_mode,'')                                     AS Line_Mode,
    NULLIF(g.line_port,'')                                     AS Line_From_Port,
    CAST(g.qtyordered AS int)                                  AS Qty_Ordered,
    CAST(g.lineamount AS decimal(18,2))                        AS Line_Amount,
    CONVERT(varchar(10),
        CAST(g.createddatetime AT TIME ZONE 'UTC'
                               AT TIME ZONE 'Pacific Standard Time' AS date), 101)
                                                               AS PO_Created,
    DATEDIFF(day, g.createddatetime, GETUTCDATE())             AS Days_Open,
    g.dataareaid                                               AS Company
FROM gaps g
CROSS JOIN health hc
LEFT JOIN dbo.vendtable vt
       ON vt.accountnum COLLATE DATABASE_DEFAULT = g.orderaccount COLLATE DATABASE_DEFAULT
      AND vt.dataareaid COLLATE DATABASE_DEFAULT = g.dataareaid   COLLATE DATABASE_DEFAULT
      AND ISNULL(vt.IsDelete,0) = 0
LEFT JOIN dbo.dirpartytable dp ON dp.recid = vt.party
WHERE hc.live_rows        >= 6500
  AND hc.distinct_classes >= 190
  AND hc.freight_rows     >= 7000

UNION ALL

/* Guidance table itself looks wrong -- say so LOUDLY instead of silently
   flagging every class on every PO as missing. */
SELECT
    'GUIDANCE TABLE UNHEALTHY - class check suppressed'        AS Alert,
    NULL, NULL, NULL, NULL, NULL,
    CONCAT('pacfreightguidance live rows = ', hc.live_rows,
           ' (expect >= 6500), distinct item classes = ', hc.distinct_classes,
           ' (expect >= 190), freight rows = ', hc.freight_rows,
           ' (expect >= 7000). The table is hand-maintained and bulk-reloaded; ',
           'this run may have landed mid-reload, or rows were deleted in error. ',
           'The item-class check was NOT run.')                AS Vendor_Name,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    '1001'
FROM health hc
WHERE hc.live_rows        < 6500
   OR hc.distinct_classes < 190
   OR hc.freight_rows     < 7000

ORDER BY 1, 2, 3;
