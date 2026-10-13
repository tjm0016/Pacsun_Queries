-- Carton detail for movement journal: 56 cartons to store 1083 (export 2026-10-13), units stranded at 1083-T
-- Source: D365 prod Synapse. Units sit in the destination transit warehouse (<towh>-T).
-- Cost = current moving-average cost (inventsum) at that -T warehouse, item+color+size.
WITH hdr AS (
  SELECT h.cartonnumber, h.fromwh, h.towh, h.overridetowh, h.cartonstatus,
         h.shippeddatetime, h.trackingnumber, h.movementfeference
  FROM paccartontransferheader h
  WHERE h.dataareaid = '1001'
    AND h.cartonnumber IN (
    'P7907980206627', 'P7884482592550', 'P7883820648286', 'P7883752763752',
    'P7883728375185', 'P7739397192838', 'P7724003224812', 'P7723976801816',
    'P7723948321032', 'P7723915764125', 'P7723883513151', 'P7722509568066',
    'P7722480907056', 'P7722461758684', 'P7722411101389', 'P7722399144717',
    'P7722351117650', 'P7722334024592', 'P7722324953040', 'P7722304932946',
    'P7722300498315', 'P7722258403834', 'P7722204159616', 'P7722187969321',
    'P7722131161284', 'P7722131139832', 'P7722096684141', 'P7722085189255',
    'P7722063833946', 'P7722007258554', 'P7721396506652', 'P7721373082134',
    'P7721344609737', 'P7721297786551', 'P7721288967912', 'P7721270479639',
    'P7721251403177', 'P7721230588573', 'P7721214665771', 'P7721186717839',
    'P7721165989730', 'P7721155052626', 'P7720688102547', 'P7720618126878',
    'P7720599176581', 'P7720582625876', 'P7720575347938', 'P7719828405019',
    'P7719817157828', 'P7719011041458', 'P7718976982620', 'P7718916683481',
    'P7718896914161', 'P7718878274844', '00000000060551102769', '00000000060550838720')
),
ln AS (
  SELECT l.cartonnumber, l.linenum, l.itemid, l.color, l.size,
         CAST(l.cartonquantity AS decimal(18,2)) AS cartonqty,
         CAST(l.receivedquantity AS decimal(18,2)) AS receivedqty
  FROM paccartontransferline l
  JOIN hdr ON hdr.cartonnumber = l.cartonnumber
  WHERE l.dataareaid = '1001'
),
dim AS (  -- one style/config per item+color+size from the released variant
  SELECT idc.itemid, id.inventcolorid, id.inventsizeid,
         MAX(id.inventstyleid) AS inventstyleid, MAX(id.configid) AS configid,
         MAX(idc.retailvariantid) AS retailvariantid
  FROM inventdimcombination idc
  JOIN inventdim id ON id.inventdimid = idc.inventdimid AND id.dataareaid = idc.dataareaid
  WHERE idc.dataareaid = '1001'
  GROUP BY idc.itemid, id.inventcolorid, id.inventsizeid
),
cost AS (  -- MAC at the transit warehouse
  SELECT s.itemid, d.inventlocationid, d.inventcolorid, d.inventsizeid,
         SUM(s.physicalinvent) AS onhand_t,
         CASE WHEN SUM(s.postedqty + s.received - s.deducted) <> 0
              THEN SUM(s.postedvalue + s.physicalvalue) / SUM(s.postedqty + s.received - s.deducted)
         END AS mac
  FROM inventsum s
  JOIN inventdim d ON d.inventdimid = s.inventdimid AND d.dataareaid = s.dataareaid
  WHERE s.dataareaid = '1001' AND s.closed = 0
    AND d.inventlocationid IN (SELECT towh + '-T' FROM hdr UNION SELECT towh FROM hdr)
  GROUP BY s.itemid, d.inventlocationid, d.inventcolorid, d.inventsizeid
)
SELECT
  hdr.cartonnumber, hdr.fromwh, hdr.towh, hdr.cartonstatus, hdr.shippeddatetime, hdr.trackingnumber,
  ln.linenum, ln.itemid, ln.color, ln.size, dim.inventstyleid, dim.configid, dim.retailvariantid,
  loc.inventsiteid                    AS site,
  hdr.towh + '-T'                     AS warehouse,
  ln.cartonqty, ln.receivedqty,
  ln.cartonqty - ln.receivedqty       AS qty_open,
  COALESCE(cost.mac, cs.mac)          AS unit_cost_mac,   -- falls back to store MAC if -T has no value
  (ln.cartonqty - ln.receivedqty) * COALESCE(cost.mac, cs.mac) AS ext_cost,
  cost.onhand_t                       AS onhand_at_transit
FROM ln
JOIN hdr ON hdr.cartonnumber = ln.cartonnumber
LEFT JOIN dim  ON dim.itemid = ln.itemid AND dim.inventcolorid = ln.color AND dim.inventsizeid = ln.size
LEFT JOIN inventlocation loc ON loc.inventlocationid = hdr.towh + '-T' AND loc.dataareaid = '1001'
LEFT JOIN cost ON cost.itemid = ln.itemid AND cost.inventcolorid = ln.color AND cost.inventsizeid = ln.size
              AND cost.inventlocationid = hdr.towh + '-T'
LEFT JOIN cost cs ON cs.itemid = ln.itemid AND cs.inventcolorid = ln.color AND cs.inventsizeid = ln.size
              AND cs.inventlocationid = hdr.towh
ORDER BY hdr.cartonnumber, ln.linenum;
