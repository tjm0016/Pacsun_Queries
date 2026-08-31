/* D365 physical on-hand at a DC by size, end of each day - the anchor for checking Robling's
   V_DWH_F_INV_ILD_B.F_OH_QTY, which is sourced from this number (Active + Lock_Code combined).
   Running balance must span ALL history; date-bounding the CTE fakes a negative opening balance.
   datephysical > '1900-01-02' drops the non-physical sentinel rows. */
WITH t AS (
  SELECT d.inventsizeid AS sz, CAST(t.datephysical AS date) AS dp, t.qty
  FROM dbo.inventtrans t
  JOIN dbo.inventdim d ON d.inventdimid = t.inventdimid AND d.dataareaid = t.dataareaid
  WHERE t.dataareaid = '1001'
    AND t.itemid = '0193-52280-0295'
    AND d.inventcolorid = '001'
    AND d.inventlocationid = '4901'
    AND t.datephysical > '1900-01-02'
    AND t.IsDelete IS NULL AND d.IsDelete IS NULL
)
SELECT sz,
  SUM(CASE WHEN dp <= '2026-08-25' THEN qty ELSE 0 END) AS d0825,
  SUM(CASE WHEN dp <= '2026-08-26' THEN qty ELSE 0 END) AS d0826,
  SUM(CASE WHEN dp <= '2026-08-27' THEN qty ELSE 0 END) AS d0827,
  SUM(CASE WHEN dp <= '2026-08-28' THEN qty ELSE 0 END) AS d0828,
  SUM(CASE WHEN dp <= '2026-08-29' THEN qty ELSE 0 END) AS d0829,
  SUM(CASE WHEN dp <= '2026-08-30' THEN qty ELSE 0 END) AS d0830,
  SUM(CASE WHEN dp <= '2026-08-31' THEN qty ELSE 0 END) AS d0831
FROM t GROUP BY sz ORDER BY sz;
