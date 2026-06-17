--Query to find items that have blank brand field
SELECT
	idc.RetailVariantId,
	idc.ItemId,
	id.inventcolorid,
	id.inventsizeid,
	idc.pacBrandId,
	idc.pacBuyerId,
	.NameAlias,
	it.pacVendorStyle,
	idc.createddatetime,
    it.product,
    ept.product
FROM
	inventdimcombination idc
JOIN 
	inventdim id
		ON id.inventdimid = idc.inventdimid
		AND id.dataareaid = idc.dataareaid
JOIN
	inventtable it
		ON it.itemid = idc.itemid
JOIN 
    EcoResProductTranslation ept
        ON ept.product = it.product
WHERE
	idc.pacBrandId IS NULL
ORDER BY
	idc.ItemID, idc.RetailVariantId

--Reference to see what is in column
SELECT TOP 5 * 
FROM EcoResProductTranslation