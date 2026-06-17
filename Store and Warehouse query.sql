--Query to find new warehouses
SELECT
	Name,
	InventLocationId,
	*
FROM 
	InventLocation
WHERE
	InventLocationId IN ('1254', '1255')

--Query to find new stores
SELECT
	StoreNumber, 
	pacOpenDate,
	*
FROM 
	RetailStoreTable
WHERE
	StoreNumber IN ('1254','1255')