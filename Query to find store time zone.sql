--Query provided by Will, doesn't work when ran as is
Select 
	TIME_ZONE, 
		Case 
			WHEN SSTR in (87, 93, 154, 572, 600, 1161) 
				THEN 'Active' 
				Else 'Closed' 
		End 
	Store_Status,
	* 
From 
	STORE
Where 
	STORE_STATE In ('AZ') 

--Time zone on All stores & Operating units
SELECT
	inventlocation,
	retailchannelid,
	ChannelTimeZone,
	*
FROM 
	RetailChannelTable rct
WHERE 
	ChannelTimeZone = '6'
ORDER BY
	rct.inventlocation

--Time zone on Warehouses
SELECT
	TimeZone,
	*
FROM
	LogisticsPostalAddress
WHERE
	TimeZone = '6'