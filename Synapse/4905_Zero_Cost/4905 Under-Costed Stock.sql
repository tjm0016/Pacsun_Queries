-- 4905 Under-Costed Stock
-- 4905 SKU-sizes (item + color + size) with on-hand > 0 whose moving-average cost is $0 or under half of fair cost.
-- Fair cost = 4901 average for the same SKU-size, else item-master cost. Run weekly; feed results to the pull-back / add-back revalue (see INV-02253604 / INV-02253606, 10/12/2026).
-- 2026-10-15: 132 SKU-sizes / 59 items / 5,234 units / $68.7K short.

WITH s AS (
  SELECT s.itemid COLLATE DATABASE_DEFAULT item, d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz,
         d.inventlocationid COLLATE DATABASE_DEFAULT wh,
         SUM(s.postedqty + s.received - s.deducted) qty, SUM(s.postedvalue + s.physicalvalue) val
  FROM inventsum s JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = s.inventdimid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(s.IsDelete,0)=0 AND s.dataareaid='1001' AND d.inventlocationid COLLATE DATABASE_DEFAULT IN ('4901','4905')
  GROUP BY s.itemid, d.inventcolorid, d.inventsizeid, d.inventlocationid
),
x AS (
  SELECT a.item, a.color, a.sz, a.qty, a.val,
         CASE WHEN b.qty>0 AND b.val>0 THEN b.val/b.qty END mac4901, m.price im
  FROM s a LEFT JOIN s b ON b.item=a.item AND b.color=a.color AND b.sz=a.sz AND b.wh='4901'
  LEFT JOIN inventtablemodule m ON m.itemid COLLATE DATABASE_DEFAULT = a.item AND m.moduletype=0 AND m.dataareaid='1001' AND ISNULL(m.IsDelete,0)=0
  WHERE a.wh='4905' AND a.qty > 0
)
SELECT item, color, COUNT(*) sizes, SUM(qty) units, SUM(val) value, SUM(qty*COALESCE(mac4901, NULLIF(im,0))) fair_value,
       SUM(qty*COALESCE(mac4901, NULLIF(im,0))) - SUM(val) gap, MAX(im) item_master
FROM x
WHERE val <= 0 OR val/qty < 0.5*COALESCE(mac4901, NULLIF(im,0))
GROUP BY item, color
ORDER BY gap DESC;
