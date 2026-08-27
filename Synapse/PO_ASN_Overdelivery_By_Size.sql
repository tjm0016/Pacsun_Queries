/*  PO ordered vs ASN vs PIX 606-03 vs posted receipt — BY SIZE
    ------------------------------------------------------------------
    Purpose: explain "overdelivery" failures on WM ASN receipts.

    D365 blocks a receipt when
        (delivered - qtyordered) / qtyordered > purchline.overdeliverypct
    PacSun runs overdeliverypct = 100, so a size posts only while
        ASN qty <= 2 x ordered qty.
    A 606-03 ASNReceipt message is all-or-nothing: ONE size over the cap
    strands every other size in the same message (see the "stuck" column).

    Tail sizes ordered 1-2 units are the usual offenders — WM ships 3-6 and
    trips 200-500% overdelivery even though the PO is short overall.

    Target: d365-synapse-ps-prod-ondemand / dataverse_psprod_...
    Set @purchid below (10-char zero-padded).
*/
DECLARE @purchid varchar(20) = '0000767085';

WITH po AS (
  SELECT d.inventsizeid COLLATE DATABASE_DEFAULT AS size, pl.linenumber,
         SUM(pl.qtyordered)          AS ordered,
         SUM(pl.remainpurchphysical) AS remaining,
         MAX(pl.overdeliverypct)     AS overdeliverypct
  FROM purchline pl
  JOIN inventdim d ON d.inventdimid = pl.inventdimid
                  AND d.dataareaid  = pl.dataareaid
                  AND ISNULL(d.IsDelete,0) = 0
  WHERE pl.purchid = @purchid AND pl.dataareaid = '1001' AND ISNULL(pl.IsDelete,0) = 0
  GROUP BY d.inventsizeid, pl.linenumber
),
asn AS (   -- what the vendor/WM ASN'd, carton level
  SELECT size COLLATE DATABASE_DEFAULT AS size,
         SUM(cartonqty)                AS asn_qty,
         COUNT(DISTINCT cartonnumber)  AS cartons
  FROM pacasncartondata
  WHERE purchid = @purchid AND ISNULL(IsDelete,0) = 0
  GROUP BY size
),
pix AS (   -- WM receipt confirmations, split by whether D365 accepted them
  SELECT p.pxszcd COLLATE DATABASE_DEFAULT AS size,
         SUM(CASE WHEN m.messagestatus = 40 THEN CAST(p.pxunrc AS bigint) ELSE 0 END)/10000.0 AS pix_ok,
         SUM(CASE WHEN m.messagestatus = 30 THEN CAST(p.pxunrc AS bigint) ELSE 0 END)/10000.0 AS pix_failed,
         SUM(CAST(p.pxunrc AS bigint))/10000.0                                                AS pix_total
  FROM pacwmpixmessage p
  JOIN sunintmessage m ON m.recid = p.message AND ISNULL(m.IsDelete,0) = 0
  WHERE p.pxpon = @purchid AND p.pxtxtp = '606' AND p.pxtxcd = '03'
    AND ISNULL(p.IsDelete,0) = 0
    AND m.messageid LIKE '%ASNReceipt%'
  GROUP BY p.pxszcd
),
rcv AS (   -- actually posted to the PO
  SELECT d.inventsizeid COLLATE DATABASE_DEFAULT AS size, SUM(v.qty) AS posted
  FROM vendpackingsliptrans v
  JOIN inventdim d ON d.inventdimid = v.inventdimid
                  AND d.dataareaid  = v.dataareaid
                  AND ISNULL(d.IsDelete,0) = 0
  WHERE v.origpurchid = @purchid       -- NOTE: origpurchid, not purchid
    AND v.dataareaid = '1001' AND ISNULL(v.IsDelete,0) = 0
  GROUP BY d.inventsizeid
)
SELECT po.linenumber                                    AS ln,
       po.size,
       CAST(po.ordered AS int)                          AS ordered,
       CAST(ISNULL(asn.asn_qty,0) AS int)               AS asn_qty,
       CAST(ISNULL(pix.pix_total,0) AS int)             AS pix_606_03,
       CAST(ISNULL(rcv.posted,0) AS int)                AS posted,
       CAST(ISNULL(pix.pix_failed,0) AS int)            AS stuck,
       CAST(ISNULL(asn.asn_qty,0) - po.ordered AS int)  AS asn_vs_ord,
       CASE WHEN po.ordered > 0
            THEN CAST(ROUND((ISNULL(asn.asn_qty,0) - po.ordered) * 100.0 / po.ordered, 0) AS int)
       END                                              AS over_pct,
       CASE WHEN po.ordered > 0
             AND (ISNULL(asn.asn_qty,0) - po.ordered) * 100.0 / po.ordered > po.overdeliverypct
            THEN '*** BLOCKS ***' ELSE '' END           AS flag
FROM po
LEFT JOIN asn ON asn.size = po.size
LEFT JOIN pix ON pix.size = po.size
LEFT JOIN rcv ON rcv.size = po.size
ORDER BY po.linenumber;


/* ---- companion 1: the exact D365 rejection text -------------------- */
SELECT m.messageid, m.messagestatus, e.createddatetime,
       CAST(e.errortext AS varchar(2000)) AS errortext
FROM sunintmessageerrorlog e
JOIN sunintmessage m ON m.recid = e.message AND ISNULL(m.IsDelete,0) = 0
WHERE m.messageid LIKE '%' + @purchid + '%ASNReceipt%'
  AND ISNULL(e.IsDelete,0) = 0
ORDER BY m.messageid, e.createddatetime;


/* ---- companion 2: which sizes each FAILED message is carrying ------ */
SELECT m.messageid, p.pxszcd AS size,
       SUM(CAST(p.pxunrc AS bigint))/10000.0 AS units
FROM pacwmpixmessage p
JOIN sunintmessage m ON m.recid = p.message AND ISNULL(m.IsDelete,0) = 0
WHERE p.pxpon = @purchid AND ISNULL(p.IsDelete,0) = 0
  AND m.messagestatus = 30 AND m.messageid LIKE '%ASNReceipt%'
GROUP BY m.messageid, p.pxszcd
ORDER BY m.messageid, p.pxszcd;


/* ---- companion 3: ASN-gate errors (shortage / hold) ---------------- */
SELECT asnid, sku, sizeid, colorid, asnqty, errortype, errorcode,
       CAST(errordescription AS varchar(500)) AS errordesc, asndate, releasehold
FROM pacasnerrortable
WHERE purchid = @purchid AND ISNULL(IsDelete,0) = 0
ORDER BY sizeid, asnid;


/* ---- companion 4: journal state (posted vs stranded item-arrival) -- */
SELECT jt.journalid, jh.posted, SUM(jt.qty) AS qty, COUNT(*) AS lines
FROM wmsjournaltrans jt
LEFT JOIN wmsjournaltable jh ON jh.journalid = jt.journalid
                            AND jh.dataareaid = jt.dataareaid
                            AND ISNULL(jh.IsDelete,0) = 0
WHERE jt.inventtransrefid = @purchid AND jt.dataareaid = '1001'
  AND ISNULL(jt.IsDelete,0) = 0
GROUP BY jt.journalid, jh.posted
ORDER BY jh.posted, jt.journalid;
