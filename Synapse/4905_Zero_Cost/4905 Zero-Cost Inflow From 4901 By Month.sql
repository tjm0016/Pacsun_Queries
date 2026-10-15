-- 4905 Zero-Cost Inflow From 4901 By Month
-- MOV-DCADJ receipt lines into 4905 at costprice 0, paired by PXTRAN/SKU/qty to the 4901 issue leg; value_lost = 4901 inventtrans cost given up.
-- 2026-10-15: $1.55M go-live to date (Jul $715K, Aug $385K).

WITH z AS (
  SELECT jl.journalid COLLATE DATABASE_DEFAULT jid, jl.pacwmpxtran px, jl.itemid COLLATE DATABASE_DEFAULT item, jl.inventdimid COLLATE DATABASE_DEFAULT dimid,
         d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz, jl.qty, jl.transdate
  FROM inventjournaltrans jl
  JOIN inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = jl.journalid COLLATE DATABASE_DEFAULT AND ISNULL(jt.IsDelete,0)=0 AND jt.posted=1
  JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = jl.inventdimid COLLATE DATABASE_DEFAULT
  WHERE ISNULL(jl.IsDelete,0)=0 AND d.inventlocationid COLLATE DATABASE_DEFAULT='4905' AND jl.qty>0 AND jl.costprice=0
    AND jt.journalnameid COLLATE DATABASE_DEFAULT='MOV-DCADJ' AND jl.transdate >= '2026-04-01'
),
p AS (
  SELECT jl.journalid COLLATE DATABASE_DEFAULT jid, jl.pacwmpxtran px, jl.itemid COLLATE DATABASE_DEFAULT item,
         d.inventcolorid COLLATE DATABASE_DEFAULT color, d.inventsizeid COLLATE DATABASE_DEFAULT sz, jl.qty, it.costamountphysical val,
         ROW_NUMBER() OVER (PARTITION BY jl.pacwmpxtran, jl.itemid, d.inventcolorid, d.inventsizeid, jl.qty ORDER BY jl.recid) rk
  FROM inventjournaltrans jl
  JOIN inventdim d ON d.inventdimid COLLATE DATABASE_DEFAULT = jl.inventdimid COLLATE DATABASE_DEFAULT
  JOIN inventtransorigin o ON o.inventtransid COLLATE DATABASE_DEFAULT = jl.inventtransid COLLATE DATABASE_DEFAULT AND ISNULL(o.IsDelete,0)=0
  JOIN inventtrans it ON it.inventtransorigin=o.recid AND ISNULL(it.IsDelete,0)=0
  WHERE ISNULL(jl.IsDelete,0)=0 AND d.inventlocationid COLLATE DATABASE_DEFAULT='4901' AND jl.qty<0
    AND jl.pacwmpxtran IN (SELECT DISTINCT px FROM z) AND jl.transdate >= '2026-03-25'
)
SELECT FORMAT(z.transdate,'yyyy-MM') wk_mon,
       COUNT(*) zero_lines, SUM(z.qty) zero_units,
       SUM(CASE WHEN p.px IS NOT NULL THEN z.qty ELSE 0 END) units_from_4901,
       -SUM(ISNULL(p.val,0)) value_lost_from_4901
FROM z
LEFT JOIN p ON p.px=z.px AND p.item=z.item AND p.color=z.color AND p.sz=z.sz AND p.qty=-z.qty AND p.rk=1
GROUP BY FORMAT(z.transdate,'yyyy-MM')
ORDER BY 1;
