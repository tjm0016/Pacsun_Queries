--Query to get all released product variants
SELECT 
	idc.itemid,
	id.inventcolorid,
	id.inventsizeid,
	idc.retailvariantid,
	idc.ProductLifecycleStateId
FROM
	inventdimcombination idc
JOIN
	inventdim id
		ON	id.inventdimid = idc.inventdimid
		AND id.dataareaid = idc.dataareaid
WHERE 
	idc.ProductLifecycleStateId = 'ACTIVE'
ORDER BY
	idc.itemid, idc.retailvariantid