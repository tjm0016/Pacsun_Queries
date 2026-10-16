/* 0860-60284 4901 vs 4905 daily movement by reference type (rc 3 = PO receipt, 4/13 = journals) for MAC replay */
SELECT it.itemid COLLATE DATABASE_DEFAULT itemid, dim.inventlocationid COLLATE DATABASE_DEFAULT wh, CAST(it.datephysical AS date) dp,
  ito.referencecategory rc, LEFT(ito.referenceid COLLATE DATABASE_DEFAULT,6) refpfx,
  SUM(CASE WHEN it.qty<0 THEN -it.qty ELSE 0 END) u_out,
  SUM(CASE WHEN it.qty<0 THEN -(CASE WHEN it.statusissue=1 THEN it.costamountposted+it.costamountadjustment ELSE it.costamountphysical END) ELSE 0 END) c_out,
  SUM(CASE WHEN it.qty>0 THEN it.qty ELSE 0 END) u_in,
  SUM(CASE WHEN it.qty>0 THEN (CASE WHEN it.statusreceipt=1 THEN it.costamountposted+it.costamountadjustment ELSE it.costamountphysical END) ELSE 0 END) c_in
FROM dbo.inventtrans it
JOIN dbo.inventtransorigin ito ON ito.recid = it.inventtransorigin
JOIN dbo.inventdim dim ON dim.inventdimid COLLATE DATABASE_DEFAULT = it.inventdimid COLLATE DATABASE_DEFAULT
WHERE it.itemid COLLATE DATABASE_DEFAULT IN ('0860-60284-0140','0860-60284-0142','0860-60284-0149')
  AND dim.inventlocationid COLLATE DATABASE_DEFAULT IN ('4901','4905')
  AND (it.statusreceipt IN (1,2) OR it.statusissue IN (1,2))
GROUP BY it.itemid COLLATE DATABASE_DEFAULT, dim.inventlocationid COLLATE DATABASE_DEFAULT, CAST(it.datephysical AS date), ito.referencecategory, LEFT(ito.referenceid COLLATE DATABASE_DEFAULT,6);
