/*
    4901 On Hand With In Transit Snapshot
    -------------------------------------
    Line-level (itemid + color + size) physical on-hand at DC warehouse 4901,
    as of the opening of a given day, with a second column giving the units for
    that same SKU sitting in the D365 in-transit warehouses (inventlocationid
    ending in '-T').

    Snapshot basis: physical posted on-hand reconstructed from inventtrans
    (datephysical is date-granular). "As of 12:01 AM on DAY" == the cumulative
    posted balance through end of the prior day, i.e. datephysical < 'DAY'.
    Use inventsum only for a CURRENT snapshot; this reconstruction is required
    for any historical point-in-time.

    In-transit ('-T') = the "In transit" warehouse bucket; a straight D365 -T
    on-hand, NOT BI's derived EOP in-transit plug.

    Parameter: change the two date literals ('2026-08-05') to the target day.
    Retail company dataareaid = 1001.
*/
SELECT
    it.itemid,
    d.inventcolorid,
    d.inventsizeid,
    SUM(CASE WHEN d.inventlocationid = '4901'   THEN it.qty ELSE 0 END) AS qty_on_hand_4901,
    SUM(CASE WHEN d.inventlocationid LIKE '%-T' THEN it.qty ELSE 0 END) AS qty_in_transit_T
FROM dbo.inventtrans it
JOIN dbo.inventdim d
    ON d.inventdimid = it.inventdimid
   AND d.dataareaid  = it.dataareaid
WHERE it.dataareaid = '1001'
  AND (d.inventlocationid = '4901' OR d.inventlocationid LIKE '%-T')
  AND it.datephysical > '1900-01-02'        -- physical postings only
  AND it.datephysical < '2026-08-05'        -- opening-of-day cutoff (< target day)
GROUP BY it.itemid, d.inventcolorid, d.inventsizeid
HAVING SUM(CASE WHEN d.inventlocationid = '4901' THEN it.qty ELSE 0 END) <> 0
ORDER BY it.itemid, d.inventcolorid, d.inventsizeid;
