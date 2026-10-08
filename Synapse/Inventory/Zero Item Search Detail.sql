-- Zero Item Search Detail
-- SKUs in warehouse 4905 with physical on-hand > 0 and zero D365 inventory value,
-- enriched with the full item hierarchy, primary vendor, item creation date and
-- first / last PO receipt dates. Source: D365 Synapse (dataverse_psprod).
-- Dates are converted UTC -> Pacific. Receipt dates = vendor PO receipts at ANY warehouse.

WITH zero_sku AS (
    SELECT s.itemid, s.inventcolorid, s.inventsizeid,
           SUM(s.physicalinvent)                 AS on_hand_units,
           SUM(s.postedvalue + s.physicalvalue)  AS d365_value,
           MAX(s.modifieddatetime)               AS last_modified_utc
    FROM inventsum s
    WHERE s.dataareaid = '1001'
      AND s.inventlocationid = '4905'
    GROUP BY s.itemid, s.inventcolorid, s.inventsizeid
    HAVING SUM(s.physicalinvent) > 0
       AND SUM(s.postedvalue + s.physicalvalue) = 0
),
rcpt AS (
    SELECT t.itemid, d.inventcolorid, d.inventsizeid,
           MIN(t.datephysical) AS first_receipt_date,
           MAX(t.datephysical) AS last_receipt_date
    FROM inventtrans t
    JOIN inventtransorigin o ON o.recid = t.inventtransorigin
    JOIN inventdim d         ON d.inventdimid = t.inventdimid AND d.dataareaid = t.dataareaid
    WHERE t.dataareaid = '1001'
      AND o.referencecategory = 3            -- Purchase order
      AND t.qty > 0
      AND t.datephysical > '1900-01-02'
      AND t.itemid IN (SELECT itemid FROM zero_sku)
    GROUP BY t.itemid, d.inventcolorid, d.inventsizeid
),
variant AS (
    SELECT idc.itemid, d.inventcolorid, d.inventsizeid, MAX(idc.retailvariantid) AS retailvariantid
    FROM inventdimcombination idc
    JOIN inventdim d ON d.inventdimid = idc.inventdimid AND d.partition = idc.partition
    WHERE idc.dataareaid = '1001'
      AND idc.itemid IN (SELECT itemid FROM zero_sku)
    GROUP BY idc.itemid, d.inventcolorid, d.inventsizeid
)
SELECT
    it.suntafclassvalue                         AS [Class],
    cl.suntafitemattributedesc                  AS [Class Name],
    it.primaryvendorid                          AS [Vendor],
    dp.name                                     AS [Vendor Name],
    it.suntafcategoryvalue                      AS [Department],
    ca.suntafitemattributedesc                  AS [Department Name],
    it.pacsubdepartmentvalue                    AS [Sub Department],
    sd.pacitemattributedesc                     AS [Sub Department Name],
    z.itemid                                    AS [Item ID],
    z.itemid + '-' + z.inventcolorid + '-' + z.inventsizeid AS [Full SKU],
    v.retailvariantid                           AS [Variant ID],
    it.namealias                                AS [Item Name],
    z.inventcolorid                             AS [Color],
    z.inventsizeid                              AS [Size],
    z.on_hand_units                             AS [On Hand Units],
    z.d365_value                                AS [D365 Value],
    CAST(z.last_modified_utc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATETIME2(0)) AS [Last Modified],
    CAST(it.createddatetime  AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS DATE)         AS [Item Creation Date],
    r.first_receipt_date                        AS [First Receipt Date],
    r.last_receipt_date                         AS [Last Receipt Date]
FROM zero_sku z
JOIN inventtable it
  ON it.itemid COLLATE DATABASE_DEFAULT = z.itemid COLLATE DATABASE_DEFAULT AND it.dataareaid = '1001'
LEFT JOIN suntafclass cl
  ON cl.suntafclassvalue COLLATE DATABASE_DEFAULT = it.suntafclassvalue COLLATE DATABASE_DEFAULT AND cl.dataareaid = '1001'
LEFT JOIN suntafcategory ca
  ON ca.suntafcategoryvalue COLLATE DATABASE_DEFAULT = it.suntafcategoryvalue COLLATE DATABASE_DEFAULT AND ca.dataareaid = '1001'
LEFT JOIN pacsubdepartment sd
  ON sd.pacsubdepartmentvalue COLLATE DATABASE_DEFAULT = it.pacsubdepartmentvalue COLLATE DATABASE_DEFAULT AND sd.dataareaid = '1001'
LEFT JOIN vendtable vt
  ON vt.accountnum COLLATE DATABASE_DEFAULT = it.primaryvendorid COLLATE DATABASE_DEFAULT AND vt.dataareaid = '1001'
LEFT JOIN dirpartytable dp
  ON dp.recid = vt.party
LEFT JOIN rcpt r
  ON r.itemid COLLATE DATABASE_DEFAULT = z.itemid COLLATE DATABASE_DEFAULT
 AND r.inventcolorid COLLATE DATABASE_DEFAULT = z.inventcolorid COLLATE DATABASE_DEFAULT
 AND r.inventsizeid  COLLATE DATABASE_DEFAULT = z.inventsizeid  COLLATE DATABASE_DEFAULT
LEFT JOIN variant v
  ON v.itemid COLLATE DATABASE_DEFAULT = z.itemid COLLATE DATABASE_DEFAULT
 AND v.inventcolorid COLLATE DATABASE_DEFAULT = z.inventcolorid COLLATE DATABASE_DEFAULT
 AND v.inventsizeid  COLLATE DATABASE_DEFAULT = z.inventsizeid  COLLATE DATABASE_DEFAULT
ORDER BY z.on_hand_units DESC;
