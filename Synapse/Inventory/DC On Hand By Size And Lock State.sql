/* D365 live on-hand for one style-color at the two DCs, split Active vs Lock_Code.
   wmslocationid is the ONLY reliable split - inventstatusid is blank on locked rows.
   Active   ~ the WM "All Inventory by SKU" unlocked feed
   Lock_Code ~ the WM DC_Locked_Inventory feed (minus the LW/LC "Lost in Warehouse"
               codes, which D365 writes off rather than holding as locked stock). */
SELECT d.inventlocationid AS wh,
       d.inventsizeid     AS sz,
       ISNULL(NULLIF(d.wmslocationid,''),'(blank)') AS wmsloc,
       SUM(s.physicalinvent)  AS physinvent,
       SUM(s.availphysical)   AS availphysical,
       SUM(s.availordered)    AS availordered,
       SUM(s.reservphysical)  AS reservphys,
       SUM(s.picked)          AS picked,
       SUM(s.onorder)         AS onorder,
       SUM(s.ordered)         AS ordered
FROM dbo.inventsum s
JOIN dbo.inventdim d
  ON d.inventdimid = s.inventdimid AND d.dataareaid = s.dataareaid
WHERE s.dataareaid = '1001'
  AND s.itemid = '0193-52280-0295'          -- itemid = class-vendor-style
  AND d.inventcolorid = '001'
  AND d.inventlocationid IN ('4901','4905')
  AND s.IsDelete IS NULL AND d.IsDelete IS NULL
GROUP BY d.inventlocationid, d.inventsizeid, ISNULL(NULLIF(d.wmslocationid,''),'(blank)')
ORDER BY 1,2,3;
