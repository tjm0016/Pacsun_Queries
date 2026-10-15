-- 4905 Primed Zero-Cost Sizes
-- Empty 4905 SKU-sizes whose most recent issue was at $0. D365's moving-average fallback (LastIssueThenActiveCostThenItemPrice)
-- will price the next receipt into these sizes at $0. Includes 4901 stock and open confirmed-PO exposure.
-- 2026-10-15: 230 sizes / 118 items / 1,873 open PO units ($22.3K).

WITH iss AS (
  SELECT it.itemid COLLATE DATABASE_DEFAULT item, d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz,
         it.qty, it.costamountphysical val,
         ROW_NUMBER() OVER (PARTITION BY it.itemid, d.inventcolorid, d.inventsizeid ORDER BY it.datephysical DESC, it.recid DESC) rn
  FROM inventtrans it JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = it.inventdimid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(it.IsDelete,0)=0 AND it.dataareaid='1001' AND d.inventlocationid COLLATE DATABASE_DEFAULT='4905'
    AND it.qty<0 AND it.statusissue IN (1,2) AND it.datephysical > '1900-01-01'
),
s AS (
  SELECT s.itemid COLLATE DATABASE_DEFAULT item, d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz,
         d.inventlocationid COLLATE DATABASE_DEFAULT wh,
         SUM(s.postedqty + s.received - s.deducted) qty, SUM(s.postedvalue + s.physicalvalue) val
  FROM inventsum s JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = s.inventdimid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(s.IsDelete,0)=0 AND s.dataareaid='1001' AND d.inventlocationid COLLATE DATABASE_DEFAULT IN ('4901','4905')
  GROUP BY s.itemid, d.inventcolorid, d.inventsizeid, d.inventlocationid
)
SELECT COUNT(DISTINCT CONCAT(i.item,i.color,i.sz)) primed_sizes, COUNT(DISTINCT i.item) items,
       SUM(CASE WHEN b.qty>0 THEN 1 ELSE 0 END) sizes_with_4901_stock,
       SUM(CASE WHEN b.qty>0 THEN b.qty ELSE 0 END) units_4901,
       SUM(CASE WHEN b.qty>0 THEN b.val ELSE 0 END) value_4901
     , SUM(ISNULL(po.openqty,0)) open_po_units, SUM(ISNULL(po.openval,0)) open_po_value,
       COUNT(DISTINCT CASE WHEN po.openqty>0 THEN CONCAT(i.item,i.color,i.sz) END) sizes_with_open_po
FROM iss i
LEFT JOIN (SELECT pl.itemid COLLATE DATABASE_DEFAULT item, d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz,
                  SUM(pl.remaininventphysical) openqty, SUM(pl.remaininventphysical*pl.paclandedcostperunit) openval
           FROM purchline pl JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = pl.inventdimid COLLATE DATABASE_DEFAULT
           JOIN purchtable pt ON pt.purchid=pl.purchid AND pt.dataareaid=pl.dataareaid
           WHERE pl.dataareaid='1001' AND ISNULL(pl.IsDelete,0)=0 AND pl.isdeleted=0 AND pl.purchstatus=1 AND pl.remaininventphysical>0
             AND pt.documentstate=40 AND d.inventlocationid COLLATE DATABASE_DEFAULT='4901'
           GROUP BY pl.itemid, d.inventcolorid, d.inventsizeid) po ON po.item=i.item AND po.color=i.color AND po.sz=i.sz
LEFT JOIN s a ON a.item=i.item AND a.color=i.color AND a.sz=i.sz AND a.wh='4905'
LEFT JOIN s b ON b.item=i.item AND b.color=i.color AND b.sz=i.sz AND b.wh='4901'
WHERE i.rn=1 AND ROUND(i.val,2)=0 AND ISNULL(a.qty,0)=0;
