--Query to find all WHSL POs with list provided by Udesh filtered out
SELECT 
	PurchID AS 'Purchase order',
	OrderAccount AS 'Vendor account',
	InvoiceAccount AS 'Invoice account',
	PurchName AS 'Vendor name',
	ItemBuyerGroupId AS 'Buyer group',
	DocumentState AS 'Approval state',
	PurchStatus AS 'Purchase order status',
	DeliveryDate AS 'Requested receipt date',
	pacSentToEDI AS 'Sent to EDI?',
	pacSentToFineline AS 'Sent to Fineline?',
	DlvMode AS 'Mode of delivery',
	MCRDropShipment AS 'Direct delivery?',
	createdDateTime AS 'Created date and time',
	modifieddatetime AS 'Modified date and time'
FROM
	PurchTable
WHERE
		ItemBuyerGroupId = 'WHSL'
	AND createddatetime >= '2026-04-06'
	AND PurchId NOT IN ('0000968157','0001025874','0000968151','0000968158','0000977786','0000968156','0000978047','0000977560','0000968150','0000968155','0001026214','0000977559','0000968128','0000968152','0001026215','0001089517','0001089518','0001091240','0001092354','0000973678','0000973683','0001034699')
UNION
SELECT 
	PurchID AS 'Purchase order',
	OrderAccount AS 'Vendor account',
	InvoiceAccount AS 'Invoice account',
	PurchName AS 'Vendor name',
	ItemBuyerGroupId AS 'Buyer group',
	DocumentState AS 'Approval state',
	PurchStatus AS 'Purchase order status',
	DeliveryDate AS 'Requested receipt date',
	pacSentToEDI AS 'Sent to EDI?',
	pacSentToFineline AS 'Sent to Fineline?',
	DlvMode AS 'Mode of delivery',
	MCRDropShipment AS 'Direct delivery?',
	createdDateTime AS 'Created date and time',
	modifieddatetime AS 'Modified date and time'
FROM
	PurchTable
WHERE
		ItemBuyerGroupId = 'WHSL'
	AND modifieddatetime >= '2026-04-06'
	AND PurchId NOT IN ('0000968157','0001025874','0000968151','0000968158','0000977786','0000968156','0000978047','0000977560','0000968150','0000968155','0001026214','0000977559','0000968128','0000968152','0001026215','0001089517','0001089518','0001091240','0001092354','0000973678','0000973683','0001034699')
ORDER BY 
	createddatetime