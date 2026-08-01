-- Net inventory movement into -T transit warehouses from the 7/15 Duplicate Carton Fix
-- journals INV-01139040 / INV-01139054 (posted 7/16/2026, transfer lines store NNNN -> NNNN-T).
-- Overlap this per-SKU with TransitPhantom_SkuDetailDiffs.diff to estimate the phantom
-- share caused by the fix over-correcting receipts that receive-by-exception had already
-- self-corrected. Synapse serverless, base tables, dataareaid 1001. 2026-07-31.
SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
       o.referenceid COLLATE DATABASE_DEFAULT AS journal,
       t.itemid COLLATE DATABASE_DEFAULT AS itemid,
       d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
       d.inventsizeid COLLATE DATABASE_DEFAULT AS size,
       SUM(t.qty) AS net_qty,
       COUNT(*) AS trans_rows
FROM inventtransorigin o
JOIN inventtrans t ON t.inventtransorigin = o.recid AND t.partition = o.partition
JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
WHERE t.dataareaid='1001'
  AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
  AND o.referenceid COLLATE DATABASE_DEFAULT IN ('INV-01139040','INV-01139054')
  AND d.inventlocationid LIKE '%-T'
GROUP BY d.inventlocationid, o.referenceid, t.itemid, d.inventcolorid, d.inventsizeid;
