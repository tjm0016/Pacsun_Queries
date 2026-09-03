/*  PO receipts by line item, straight from the WM PIX messages
    ----------------------------------------------------------
    "How much did the DC actually receive against this PO, by line/size,
     according to WM -- not according to what D365 managed to post?"

    PIX 606 / code 03 (action code blank) is the ASN inbound receipt
    confirmation.  It is the message D365 builds and posts the item-arrival
    journal from, so it is the WM-side truth for received units, independent
    of whether the D365 posting succeeded.

    Notes / gotchas
      - RTRIM() is required on pxtxtp / pxtxcd / pxpon.  pacwmpixmessage is
        fixed-width padded, so bare = '606' silently returns zero rows.
      - pxunrc is type 15S4 -> divide by 10,000 for units.
      - One 606-03 message = one carton (pxcasn).
      - pxpoln is the HEAD line of a colour/size-scale block, not the D365
        line number.  On a single-colour PO it happens to line up 1:1; on a
        multi-colour PO every size in the block reports the same pxpoln, so
        match to purchline by (block head, size), which is what query 3 does.
      - 603 / 02 with a blank action code is the per-line receiving-close
        total.  Useful cross-check, but it stops at the moment receiving
        closed -- cartons received afterwards only show up in 606-03.
      - vendpackingsliptrans has origpurchid, NOT purchid.
      - Anything with a WM event before 2026-04-15 has no PIX archive
        fallback; if pacwmpixmessage has not got it, it is gone.
*/

DECLARE @po varchar(20) = '0000766939';   -- 10-digit, zero padded


/* 1 -- what PIX traffic exists for this PO at all (orientation) */
SELECT  pxtxtp, pxtxcd, pxaccd,
        COUNT(*)                                AS msgs,
        SUM(TRY_CAST(pxunrc AS bigint))/10000.0 AS units_received,
        MIN(createddatetime)                    AS first_utc,
        MAX(createddatetime)                    AS last_utc
FROM    dbo.pacwmpixmessage
WHERE   RTRIM(pxpon) = @po
GROUP BY pxtxtp, pxtxcd, pxaccd
ORDER BY pxtxtp, pxtxcd, pxaccd;


/* 2 -- receipts by line item, PIX only */
SELECT  RTRIM(pxpon)                            AS po,
        TRY_CAST(pxpoln AS int)                 AS pix_po_line,
        RTRIM(pxstyl) + '-' + RTRIM(pxssfx) + '-' + RTRIM(pxcolr) AS itemid,
        RTRIM(pxszcd)                           AS size_code,
        RTRIM(pxwhse)                           AS wm_whse,
        COUNT(*)                                AS pix_msgs,
        COUNT(DISTINCT RTRIM(pxcasn))           AS cartons,
        SUM(TRY_CAST(pxunrc AS bigint))/10000.0 AS units_received,
        MIN(createddatetime)                    AS first_msg_utc,
        MAX(createddatetime)                    AS last_msg_utc
FROM    dbo.pacwmpixmessage
WHERE   RTRIM(pxpon)  = @po
  AND   RTRIM(pxtxtp) = '606'
  AND   RTRIM(pxtxcd) = '03'
GROUP BY RTRIM(pxpon), TRY_CAST(pxpoln AS int), RTRIM(pxstyl), RTRIM(pxssfx),
         RTRIM(pxcolr), RTRIM(pxszcd), RTRIM(pxwhse)
ORDER BY pix_po_line, size_code;


/* 3 -- the reconciliation: ordered vs WM-received vs D365-posted, per line.
        A positive recv_less_ordered flags an overdelivery candidate (the usual
        cause of an atomic PIX rollback); a positive pix_less_posted is stuck
        receipts -- physically received at the DC, never posted in D365.       */
WITH pix AS (
    SELECT  TRY_CAST(pxpoln AS int)                 AS pix_head_line,
            RTRIM(pxszcd)                           AS size_code,
            COUNT(DISTINCT RTRIM(pxcasn))           AS cartons,
            COUNT(*)                                AS pix_msgs,
            SUM(TRY_CAST(pxunrc AS bigint))/10000.0 AS units_received,
            MIN(createddatetime)                    AS first_msg_utc,
            MAX(createddatetime)                    AS last_msg_utc
    FROM    dbo.pacwmpixmessage
    WHERE   RTRIM(pxpon)  = @po
      AND   RTRIM(pxtxtp) = '606'
      AND   RTRIM(pxtxcd) = '03'
    GROUP BY TRY_CAST(pxpoln AS int), RTRIM(pxszcd)
),
lines AS (
    SELECT  p.linenumber                        AS d365_line,
            RTRIM(p.itemid)                     AS itemid,
            RTRIM(d.inventcolorid)              AS colorid,
            RTRIM(d.inventsizeid)               AS sizeid,
            RTRIM(d.inventlocationid)           AS warehouse,
            p.purchqty                          AS qty_ordered,
            p.remainpurchphysical,
            p.purchstatus,
            p.overdeliverypct,
            /* the PIX block this line belongs to = the greatest pxpoln <= linenumber */
            (SELECT MAX(x.pix_head_line) FROM pix x
              WHERE x.pix_head_line <= p.linenumber) AS pix_head_line
    FROM    dbo.purchline p
    JOIN    dbo.inventdim d
           ON d.inventdimid = p.inventdimid AND d.dataareaid = p.dataareaid
    WHERE   RTRIM(p.purchid) = @po
),
posted AS (
    SELECT  v.purchaselinelinenumber AS d365_line,
            SUM(v.qty)               AS qty_posted
    FROM    dbo.vendpackingsliptrans v
    WHERE   RTRIM(v.origpurchid) = @po
    GROUP BY v.purchaselinelinenumber
)
SELECT  l.d365_line, l.itemid, l.colorid, l.sizeid, l.warehouse,
        l.qty_ordered,
        ISNULL(x.cartons, 0)                             AS pix_cartons,
        ISNULL(x.pix_msgs, 0)                            AS pix_msgs,
        ISNULL(x.units_received, 0)                      AS pix_units_received,
        ISNULL(x.units_received, 0) - l.qty_ordered      AS recv_less_ordered,
        ISNULL(s.qty_posted, 0)                          AS d365_posted,
        ISNULL(x.units_received, 0) - ISNULL(s.qty_posted, 0) AS pix_less_posted,
        l.qty_ordered * (1 + l.overdeliverypct / 100.0)  AS overdelivery_cap,
        l.remainpurchphysical, l.purchstatus, l.overdeliverypct,
        x.first_msg_utc, x.last_msg_utc
FROM    lines l
LEFT JOIN pix    x ON x.pix_head_line = l.pix_head_line AND x.size_code = l.sizeid
LEFT JOIN posted s ON s.d365_line     = l.d365_line
WHERE   l.qty_ordered <> 0 OR x.units_received IS NOT NULL OR s.qty_posted IS NOT NULL
ORDER BY l.d365_line, l.sizeid;


/* 4 -- cross-check: the receiving-close totals WM sent per line (603/02, blank AC) */
SELECT  TRY_CAST(pxpoln AS int)                 AS pix_po_line,
        RTRIM(pxszcd)                           AS size_code,
        SUM(TRY_CAST(pxunrc AS bigint))/10000.0 AS units_at_close,
        MAX(createddatetime)                    AS close_utc
FROM    dbo.pacwmpixmessage
WHERE   RTRIM(pxpon)  = @po
  AND   RTRIM(pxtxtp) = '603'
  AND   RTRIM(pxtxcd) = '02'
  AND   RTRIM(pxaccd) = ''
GROUP BY TRY_CAST(pxpoln AS int), RTRIM(pxszcd)
ORDER BY pix_po_line, size_code;
