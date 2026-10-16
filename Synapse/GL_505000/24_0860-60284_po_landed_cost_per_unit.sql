/* PO landed cost per unit: 14368xx (air, ~$19/u) vs 13689xx (ocean, ~$11-12/u) for 0860-60284 */
SELECT pl.purchid, pl.itemid, dim.inventcolorid, dim.inventsizeid, pl.purchprice, pl.qtyordered, pl.pacLandedCostTotal, pl.lineamount, pl.purchstatus,
  CASE WHEN pl.qtyordered<>0 THEN pl.pacLandedCostTotal/pl.qtyordered END lc_per_u
FROM dbo.purchline pl LEFT JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = pl.inventdimid COLLATE DATABASE_DEFAULT
WHERE pl.purchid IN ('0001436838','0001436839','0001436842','0001368987','0001368986','0001368993','0001368994','0001368979','0001368981')
  AND ISNULL(pl.IsDelete,0)=0 AND pl.isdeleted=0
ORDER BY 1,4;
