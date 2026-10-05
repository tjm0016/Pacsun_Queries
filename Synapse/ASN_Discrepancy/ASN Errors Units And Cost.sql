-- ASN receipt errors (stuck 606-03 ASNReceipt / CreateManualASN child messages) - units and cost
WITH msg AS (
    SELECT m.recid, m.messageid, m.messagestatus, m.createddatetime
    FROM dbo.sunintmessage m
    WHERE (m.messageid LIKE '%ASNReceipt%' OR m.messageid LIKE '%CreateManualASN%')
      AND m.messagestatus NOT IN (40, 50)          -- 30 Error + orphaned 10/20
      AND ISNULL(m.IsDelete, 0) = 0
),
lasterr AS (
    SELECT e.message, e.errortext,
           ROW_NUMBER() OVER (PARTITION BY e.message ORDER BY e.createddatetime DESC, e.recid DESC) AS rn,
           COUNT(*)     OVER (PARTITION BY e.message) AS tries
    FROM dbo.sunintmessageerrorlog e
    WHERE e.message IN (SELECT recid FROM msg)
),
pix AS (
    SELECT p.message,
           p.pxpon                                   AS purchid,
           p.pxstyl + '-' + p.pxssfx + '-' + p.pxcolr AS itemid,
           p.pxsdim                                  AS colorid,
           p.pxszcd                                  AS sizeid,
           SUM(CAST(CASE WHEN p.pxtxtp = '617' THEN p.pxunsh ELSE p.pxunrc END   -- manual ASN carries shipped, receipt carries received
                    AS decimal(19,4)) / 10000) AS units
    FROM dbo.pacwmpixmessage p
    WHERE p.message IN (SELECT recid FROM msg)
    GROUP BY p.message, p.pxpon, p.pxstyl, p.pxssfx, p.pxcolr, p.pxsdim, p.pxszcd
),
price AS (   -- one price per PO/item/color/size (live, non-deleted lines)
    SELECT pl.purchid, pl.itemid, d.inventcolorid, d.inventsizeid,
           MAX(pl.purchprice) AS unitcost
    FROM dbo.purchline pl
    JOIN dbo.inventdim d ON d.inventdimid = pl.inventdimid AND d.dataareaid = pl.dataareaid
    WHERE ISNULL(pl.IsDelete, 0) = 0 AND pl.isdeleted = 0 AND pl.itemid IS NOT NULL
      AND pl.purchid IN (SELECT purchid FROM pix)
    GROUP BY pl.purchid, pl.itemid, d.inventcolorid, d.inventsizeid
)
SELECT m.messageid,
       m.messagestatus,
       m.createddatetime,
       x.purchid, x.itemid, x.colorid, x.sizeid,
       x.units,
       pr.unitcost,
       x.units * pr.unitcost AS extcost,
       le.tries,
       le.errortext          AS last_error
FROM msg m
JOIN pix x               ON x.message = m.recid
LEFT JOIN price pr       ON pr.purchid = x.purchid
                        AND pr.itemid = x.itemid
                        AND pr.inventcolorid = x.colorid
                        AND pr.inventsizeid = x.sizeid
LEFT JOIN lasterr le     ON le.message = m.recid AND le.rn = 1
ORDER BY x.purchid, m.messageid, x.itemid, x.sizeid;
