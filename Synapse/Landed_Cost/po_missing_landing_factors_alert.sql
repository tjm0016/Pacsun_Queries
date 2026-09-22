/* ============================================================================
   D365_PO_Missing_Landing_Factors  --  daily email report
   ----------------------------------------------------------------------------
   Open FOB purchase orders whose LINES are missing (or contradict) one of the
   inputs the landed-cost estimate needs:

       From Port   purchline.itmfromport       |  pacFreightGuidance lookup key
       Mode        purchline.dlvmode           |  (FromPort x DlvTerm x DlvMode
       Terms       purchline.dlvterm           |   x ItemClass)
       Duty %      purchline.pacdutypercent    -> duty charge at invoice time
       Freight $   purchline.paclandedcosttotal (= lineamount + applied charges)

   pacApplyLandFactorEstimatesService reads the LINE, not the header. A blank
   line value falls through to the wildcard rate rows in pacFreightGuidance
   (findSpecificCharges matches FromPort = x OR FromPort = ''), so the PO lands
   with no estimate -- or, if the line carries a DIFFERENT value than the
   header, it wins the specific rate for the WRONG lane.

   Scope
     dlvterm = 'FOB'  -- PacSun pays duty + freight, so landing factors apply.
                         DDP / DDP_VW / DDP_CA are vendor-paid (0 duty by
                         design; only 49 of 6,725 carry a port) and are NOT a gap.
     purchstatus = 1  -- Backorder, read off the LINE, not the header.
                         Corrected 2026-09-21. pacApplyLandFactorEstimatesService
                         filters `purchLine.PurchStatus == PurchStatus::Backorder`,
                         so a line that is already received, invoiced or cancelled
                         will never be priced again no matter what is fixed on it.
                         Scoping on purchtable.purchstatus swept in 7,547 such
                         lines / $20.6M across the open population -- rows the PO
                         team cannot action.
     dataareaid  = '1001'

   Filters: purchtable  ISNULL(IsDelete,0)=0                 (CDC tombstone)
            purchline   ISNULL(IsDelete,0)=0 AND isdeleted=0 (D365 keeps deleted
                        lines as rows with isdeleted=1, qty zeroed)
   Notes  : COLLATE DATABASE_DEFAULT on every string compare -- purchtable and
            purchline land on different collations in the serverless pool.
            Rollups are GROUP BY, never a CTE self-join on string keys.

   Duty CONFLICTS (line % <> header %) are deliberately NOT flagged: duty is
   HTS-code specific, so it legitimately varies per item. Flagging it added 203
   false positives. Port / Mode conflicts ARE flagged (1 and 3 POs) -- there the
   line wins a specific rate for the wrong lane.

   Sized 2026-09-20: 1,292 open FOB POs -> 418 with a missing value (274 port,
   229 duty, 44 freight, 27 mode) + 4 with a port/mode conflict. 13 of the 418
   were created in the last 7 days, so this starts as a ~420-row backlog and
   then runs as a new-arrivals alert. 409 of the 418 are buyer-created
   (JBagwell 137, LJones 99, Admin 137, JWaweru 27, HHuynh 9); only 9 come from
   the integration 2xxxxxxxxx series.
   ============================================================================ */
WITH l AS (
    SELECT
        h.purchid,
        h.dataareaid,
        h.orderaccount,
        h.purchname,
        h.deliverydate,
        ISNULL(h.createdby,'')                          AS created_by,
        h.createddatetime,
        ISNULL(h.itmfromport,'')                        AS hdr_port,
        ISNULL(h.dlvmode,'')                            AS hdr_mode,
        ISNULL(h.dlvterm,'')                            AS hdr_term,
        ISNULL(h.pacdutypercent,0)                      AS hdr_duty,
        ISNULL(pl.itmfromport,'')                       AS line_port,
        ISNULL(pl.dlvmode,'')                           AS line_mode,
        ISNULL(pl.pacdutypercent,0)                     AS line_duty,
        ISNULL(pl.paclandedcosttotal,0)                 AS line_landed,
        ISNULL(pl.lineamount,0)                         AS line_amount,
        ISNULL(pl.qtyordered,0)                         AS qtyordered
    FROM dbo.purchtable h
    JOIN dbo.purchline  pl
      ON pl.purchid    COLLATE DATABASE_DEFAULT = h.purchid    COLLATE DATABASE_DEFAULT
     AND pl.dataareaid COLLATE DATABASE_DEFAULT = h.dataareaid COLLATE DATABASE_DEFAULT
    WHERE ISNULL(h.IsDelete,0) = 0
      AND ISNULL(pl.IsDelete,0) = 0
      AND pl.isdeleted = 0
      AND pl.purchstatus = 1          -- Backorder, read off the LINE (see note below)
      AND h.dataareaid = '1001'
      AND h.dlvterm COLLATE DATABASE_DEFAULT = 'FOB'
      /* Drop the ENTIRE PO if ANY line has been received or invoiced -- Tyler
         2026-09-21: "if any line is received or invoiced it should not be on the
         report". A partially received PO is past the point where correcting the
         landing factors is worth doing, even on its still-open lines. */
      AND NOT EXISTS (
            SELECT 1
            FROM dbo.purchline x
            WHERE x.purchid    COLLATE DATABASE_DEFAULT = pl.purchid    COLLATE DATABASE_DEFAULT
              AND x.dataareaid COLLATE DATABASE_DEFAULT = pl.dataareaid COLLATE DATABASE_DEFAULT
              AND ISNULL(x.IsDelete,0) = 0
              AND x.isdeleted = 0
              AND x.purchstatus IN (2, 3)   -- 2 Received, 3 Invoiced
          )
), p AS (
    SELECT
        purchid, dataareaid, orderaccount, purchname, deliverydate, created_by,
        MIN(createddatetime)                                            AS createddatetime,
        MAX(hdr_port)                                                   AS hdr_port,
        MAX(hdr_mode)                                                   AS hdr_mode,
        MAX(hdr_term)                                                   AS hdr_term,
        MAX(hdr_duty)                                                   AS hdr_duty,
        COUNT(*)                                                        AS lines_total,
        SUM(CASE WHEN line_port = '' THEN 1 ELSE 0 END)                 AS miss_port,
        SUM(CASE WHEN line_mode = '' THEN 1 ELSE 0 END)                 AS miss_mode,
        SUM(CASE WHEN line_duty = 0  THEN 1 ELSE 0 END)                 AS miss_duty,
        SUM(CASE WHEN line_amount > 0
                  AND line_landed <= line_amount THEN 1 ELSE 0 END)     AS miss_freight,
        SUM(CASE WHEN line_port <> ''
                  AND line_port COLLATE DATABASE_DEFAULT
                   <> hdr_port  COLLATE DATABASE_DEFAULT THEN 1 ELSE 0 END) AS conflict_port,
        SUM(CASE WHEN line_mode <> ''
                  AND line_mode COLLATE DATABASE_DEFAULT
                   <> hdr_mode  COLLATE DATABASE_DEFAULT THEN 1 ELSE 0 END) AS conflict_mode,
        SUM(qtyordered)                                                 AS units,
        SUM(line_amount)                                                AS line_amount
    FROM l
    GROUP BY purchid, dataareaid, orderaccount, purchname, deliverydate, created_by
)
SELECT
    p.purchid                                                   AS PO,
    p.orderaccount                                              AS Vendor_Account,
    COALESCE(NULLIF(dp.name,''), NULLIF(p.purchname,''))        AS Vendor_Name,
    /* which landing-factor inputs are BLANK on at least one line */
    STUFF(
        CASE WHEN p.miss_port    > 0 THEN ', From Port' ELSE '' END +
        CASE WHEN p.miss_mode    > 0 THEN ', Mode'      ELSE '' END +
        CASE WHEN p.miss_duty    > 0 THEN ', Duty'      ELSE '' END +
        CASE WHEN p.miss_freight > 0 THEN ', Freight'   ELSE '' END, 1, 2, '')
                                                                AS Missing_On_Lines,
    /* line carries a DIFFERENT value than the header - wrong-lane rate */
    STUFF(
        CASE WHEN p.conflict_port > 0 THEN ', From Port' ELSE '' END +
        CASE WHEN p.conflict_mode > 0 THEN ', Mode'      ELSE '' END, 1, 2, '')
                                                                AS Conflicts_With_Header,
    p.lines_total                                               AS Lines_Total,
    p.miss_port                                                 AS Lines_No_Port,
    p.miss_mode                                                 AS Lines_No_Mode,
    p.miss_duty                                                 AS Lines_No_Duty,
    p.miss_freight                                              AS Lines_No_Freight,
    NULLIF(p.hdr_port,'')                                       AS Header_Port,
    NULLIF(p.hdr_mode,'')                                       AS Header_Mode,
    CAST(p.hdr_duty AS decimal(10,2))                           AS Header_Duty_Pct,
    p.hdr_term                                                  AS Delivery_Terms,
    CAST(p.units AS int)                                        AS Units_Ordered,
    CAST(p.line_amount AS decimal(18,2))                        AS Line_Amount,
    CASE WHEN p.deliverydate >= CAST(GETUTCDATE() AS date)
         THEN 'Upcoming' ELSE 'Past due' END                    AS Delivery_Status,
    CONVERT(varchar(10), p.deliverydate, 101)                   AS Delivery_Date,
    DATEDIFF(day, CAST(GETUTCDATE() AS date), p.deliverydate)   AS Days_To_Delivery,
    p.created_by                                                AS Created_By,
    CONVERT(varchar(10),
        CAST(p.createddatetime AT TIME ZONE 'UTC'
                               AT TIME ZONE 'Pacific Standard Time' AS date), 101)
                                                                AS Created_Date,
    p.dataareaid                                                AS Company
FROM p
LEFT JOIN dbo.vendtable     vt ON vt.accountnum COLLATE DATABASE_DEFAULT = p.orderaccount COLLATE DATABASE_DEFAULT
                              AND vt.dataareaid COLLATE DATABASE_DEFAULT = p.dataareaid   COLLATE DATABASE_DEFAULT
LEFT JOIN dbo.dirpartytable dp ON dp.recid = vt.party
WHERE p.miss_port     > 0
   OR p.miss_mode     > 0
   OR p.miss_duty     > 0
   OR p.miss_freight  > 0
   OR p.conflict_port > 0
   OR p.conflict_mode > 0
/* Upcoming deliveries first (soonest = most urgent to fix before receipt), then
   past-due most-recent-first. A plain deliverydate ASC put 2023 dead POs at the
   top of the email, which is the opposite of actionable. */
ORDER BY CASE WHEN p.deliverydate >= CAST(GETUTCDATE() AS date) THEN 0 ELSE 1 END,
         CASE WHEN p.deliverydate >= CAST(GETUTCDATE() AS date) THEN p.deliverydate END ASC,
         p.deliverydate DESC,
         p.purchid;
