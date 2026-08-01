-- ROOT CAUSE: why the 7/15 Duplicate Carton Fix journals (INV-01139040/054, posted
-- 7/16/2026) over-corrected. Two standalone queries; join their outputs per store+SKU.
--
-- Q1 result (2026-08-01): of 96,536 fix units into -T --
--   48,769 landed on SKUs where -T was NEGATIVE (real hole from a single-ship/double-
--          receipt carton) -> fix was CORRECT; 14,184 SKUs matched the hole exactly.
--   44,360 landed where -T was EXACTLY ZERO and 3,407 where it was already positive
--          -> 49,688 units of phantom created.
-- Q2 result: 13,457 of the 13,458 phantom SKUs (49,687 of 49,688 units) show pre-fix
--   CTN-MOV (receive-by-exception) wash activity at -T -> those cartons had ALREADY
--   been self-corrected at receive time; store books were right; the fix should not
--   have touched them. Remediation = reverse fix (-T -> store), NOT write-off, NOT 4901.
-- Synapse serverless prod, base tables, dataareaid 1001.

-- ============================================================================
-- Q1. Pre-fix -T net balance per fix-journal store+SKU
--     (all non-fix inventtrans; datephysical < 2026-07-16 = balance the fix saw).
-- ============================================================================
WITH fixsku AS (
  SELECT DISTINCT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         t.itemid COLLATE DATABASE_DEFAULT AS itemid,
         d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
         d.inventsizeid COLLATE DATABASE_DEFAULT AS size
  FROM inventtrans t
  JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
  JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
  WHERE t.dataareaid='1001'
    AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
    AND o.referenceid COLLATE DATABASE_DEFAULT IN ('INV-01139040','INV-01139054')
    AND d.inventlocationid LIKE '%-T'
),
nonfix AS (
  SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         t.itemid COLLATE DATABASE_DEFAULT AS itemid,
         d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
         d.inventsizeid COLLATE DATABASE_DEFAULT AS size,
         SUM(CASE WHEN t.datephysical < '2026-07-16' THEN t.qty ELSE 0 END) AS pre_fix_net,
         SUM(CASE WHEN t.datephysical >= '2026-07-16' THEN t.qty ELSE 0 END) AS post_fix_net
  FROM inventtrans t
  JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
  JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
  WHERE t.dataareaid='1001'
    AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
    AND o.referenceid COLLATE DATABASE_DEFAULT NOT IN ('INV-01139040','INV-01139054')
    AND d.inventlocationid LIKE '%-T'
  GROUP BY d.inventlocationid, t.itemid, d.inventcolorid, d.inventsizeid
)
SELECT f.twh, f.itemid, f.color, f.size,
       ISNULL(n.pre_fix_net, 0)  AS pre_fix_net,
       ISNULL(n.post_fix_net, 0) AS post_fix_net
FROM fixsku f
LEFT JOIN nonfix n
  ON n.twh = f.twh AND n.itemid = f.itemid AND n.color = f.color AND n.size = f.size;

-- ============================================================================
-- Q2. Pre-fix CTN-MOV (receive-by-exception) wash activity at -T per fix SKU.
--     wash_pos > 0 = an exception journal already corrected this carton at receipt.
-- ============================================================================
WITH fixsku AS (
  SELECT DISTINCT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         t.itemid COLLATE DATABASE_DEFAULT AS itemid,
         d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
         d.inventsizeid COLLATE DATABASE_DEFAULT AS size
  FROM inventtrans t
  JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
  JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
  WHERE t.dataareaid='1001'
    AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
    AND o.referenceid COLLATE DATABASE_DEFAULT IN ('INV-01139040','INV-01139054')
    AND d.inventlocationid LIKE '%-T'
),
ctnmov AS (
  SELECT d.inventlocationid COLLATE DATABASE_DEFAULT AS twh,
         t.itemid COLLATE DATABASE_DEFAULT AS itemid,
         d.inventcolorid COLLATE DATABASE_DEFAULT AS color,
         d.inventsizeid COLLATE DATABASE_DEFAULT AS size,
         SUM(CASE WHEN t.qty > 0 THEN t.qty ELSE 0 END) AS wash_pos,
         SUM(CASE WHEN t.qty < 0 THEN t.qty ELSE 0 END) AS wash_neg
  FROM inventtrans t
  JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
  JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
  JOIN inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = o.referenceid COLLATE DATABASE_DEFAULT
       AND jt.dataareaid = '1001' AND ISNULL(jt.IsDelete,0)=0
  WHERE t.dataareaid='1001'
    AND ISNULL(t.IsDelete,0)=0 AND ISNULL(o.IsDelete,0)=0 AND ISNULL(d.IsDelete,0)=0
    AND jt.journalnameid COLLATE DATABASE_DEFAULT = 'CTN-MOV'
    AND d.inventlocationid LIKE '%-T'
    AND t.datephysical < '2026-07-16'
  GROUP BY d.inventlocationid, t.itemid, d.inventcolorid, d.inventsizeid
)
SELECT f.twh, f.itemid, f.color, f.size,
       ISNULL(c.wash_pos, 0) AS wash_pos,
       ISNULL(c.wash_neg, 0) AS wash_neg
FROM fixsku f
LEFT JOIN ctnmov c
  ON c.twh = f.twh AND c.itemid = f.itemid AND c.color = f.color AND c.size = f.size;
