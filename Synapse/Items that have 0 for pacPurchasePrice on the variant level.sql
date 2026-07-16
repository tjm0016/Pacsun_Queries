--Items that have 0 for pacPurchasePrice on the variant level 
SELECT 
	idc.retailvariantid,
	idc.itemid,
	id.inventcolorid,
	id.inventsizeid,
	it.pacvendorstyle,
	it.namealias,
	idc.pacBuyerId,
	idc.pacpurchprice,
	idc.createddatetime
FROM
	inventdimcombination idc
JOIN
	inventdim id
		ON id.InventDimId = idc.InventDimId
            AND id.DataAreaId = idc.DataAreaId
JOIN 
	inventtable it
		ON idc.ItemId = it.ItemId
			AND idc.dataareaid = it.dataareaid
WHERE
	idc.pacpurchprice = '0'
	--AND it.ItemId IN ('0128-60985-0075','0131-61111-0035','0141-48426-0061','0141-48426-0062','0141-48426-0063','0180-61111-0027','0180-61111-0028','0180-61114-0277','0740-60985-0055','0751-48426-0142','0783-61114-0008','0783-61114-0009','0783-61114-0010','0783-61114-0014','0784-60489-0063','0788-48426-0194','0788-48426-0198','0821-48426-0038','0850-48426-0072')
ORDER BY 
	idc.pacbuyerid, idc.createddatetime, idc.itemid, id.inventcolorid