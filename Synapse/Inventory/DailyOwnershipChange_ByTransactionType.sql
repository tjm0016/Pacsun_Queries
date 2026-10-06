-- Daily change in TOTAL units owned (all RETAIL-site warehouses: stores + DCs + -T) by transaction type.
-- Proves carton transfers (ship DC->-T, receive -T->store) never change total ownership: they net 0 every day,
-- whatever time they post. Validated 2026-10-06 for 8/16-8/22/2026: daily totals tie to the 'D365 OH' export
-- day-over-day change exactly; carton transfers = 0, CTN-MOV = -2. Synapse serverless prod, company 1001.
DECLARE @from date = '2026-08-16', @to date = '2026-08-22';
SELECT CAST(t.datephysical AS date) AS dphys,
       CASE o.referencecategory WHEN 0 THEN 'Sales' WHEN 3 THEN 'Purchase receipts'
            WHEN 6 THEN CASE WHEN jt.journalnameid LIKE 'CTN-%' THEN 'Carton transfers (ship + receive)' ELSE 'Other transfer journals' END
            WHEN 4 THEN CASE WHEN jt.journalnameid LIKE 'CTN-%' THEN 'Carton variances (CTN-MOV)' ELSE 'Movement journals (DC sync, RFID, adj.)' END
            ELSE 'Other (' + CAST(o.referencecategory AS varchar(5)) + ')' END AS txn_type,
       SUM(t.qty) AS qty
FROM inventtrans t
JOIN inventtransorigin o ON t.inventtransorigin = o.recid AND t.partition = o.partition
JOIN inventdim d ON t.inventdimid = d.inventdimid AND t.dataareaid = d.dataareaid AND t.partition = d.partition
LEFT JOIN inventjournaltable jt ON jt.journalid COLLATE DATABASE_DEFAULT = o.referenceid COLLATE DATABASE_DEFAULT
     AND jt.dataareaid = '1001' AND ISNULL(jt.IsDelete,0) = 0
WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0 AND ISNULL(o.IsDelete,0) = 0 AND ISNULL(d.IsDelete,0) = 0
  AND d.inventsiteid = 'RETAIL'
  AND (t.statusreceipt IN (1,2) OR t.statusissue IN (1,2))
  AND t.datephysical >= @from AND t.datephysical <= @to
GROUP BY CAST(t.datephysical AS date),
       CASE o.referencecategory WHEN 0 THEN 'Sales' WHEN 3 THEN 'Purchase receipts'
            WHEN 6 THEN CASE WHEN jt.journalnameid LIKE 'CTN-%' THEN 'Carton transfers (ship + receive)' ELSE 'Other transfer journals' END
            WHEN 4 THEN CASE WHEN jt.journalnameid LIKE 'CTN-%' THEN 'Carton variances (CTN-MOV)' ELSE 'Movement journals (DC sync, RFID, adj.)' END
            ELSE 'Other (' + CAST(o.referencecategory AS varchar(5)) + ')' END
