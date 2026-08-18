/* ============================================================================
   GL 505840 "DC to ERP over/short variances" - SKU-level journal transactions
   Since D365 go-live (first 505840 posting = 2026-04-07).
   Grain: one row per posted inventory transaction on a voucher that hit 505840.
   Tie-out: SUM(GL505840_Amount) = the 505840 net for all inventory-sourced
            postings (postingtype 93 InventProfit / 94 InventLoss).
   ============================================================================ */
WITH v AS (          -- every voucher that touched main account 505840
  SELECT ge.subledgervoucher COLLATE DATABASE_DEFAULT AS voucher,
         MIN(CAST(ge.accountingdate AS date))           AS accountingdate,
         MIN(ge.journalnumber COLLATE DATABASE_DEFAULT) AS gl_journalnumber
  FROM dbo.generaljournalaccountentry gae
  JOIN dbo.generaljournalentry ge
        ON ge.recid = gae.generaljournalentry AND ge.partition = gae.partition
  JOIN dbo.mainaccount ma
        ON ma.recid = gae.mainaccount AND ma.partition = gae.partition
  WHERE ma.mainaccountid = '505840'
    AND ISNULL(gae.IsDelete,0)=0 AND ISNULL(ge.IsDelete,0)=0
  GROUP BY ge.subledgervoucher COLLATE DATABASE_DEFAULT
)
SELECT
    v.accountingdate                                        AS AccountingDate,
    CAST(it.datephysical AS date)                           AS TransDate,
    it.voucherphysical                                      AS Voucher,
    v.gl_journalnumber                                      AS GLJournalNumber,
    ito.referenceid                                         AS JournalId,
    ISNULL(jt.journalnameid,'')                             AS JournalName,
    ISNULL(jt.description,'')                               AS JournalDescription,
    ito.referencecategory                                   AS RefCategory,
    it.itemid                                               AS ItemId,
    ISNULL(idim.inventcolorid,'')                           AS ColorId,
    ISNULL(idim.inventsizeid,'')                            AS SizeId,
    it.itemid + '-' + ISNULL(idim.inventcolorid,'') + '-' + ISNULL(idim.inventsizeid,'') AS SKU,
    ISNULL(idim.inventlocationid,'')                        AS Warehouse,
    ISNULL(il.name,'')                                      AS WarehouseName,
    ISNULL(idim.wmslocationid,'')                           AS WMSBucket,
    it.qty                                                  AS Qty,
    it.costamountphysical                                   AS InventoryCost,
    -it.costamountphysical                                  AS GL505840_Amount
FROM dbo.inventtrans it
JOIN v   ON v.voucher = it.voucherphysical COLLATE DATABASE_DEFAULT
JOIN dbo.inventtransorigin ito
      ON ito.recid = it.inventtransorigin AND ito.partition = it.partition
LEFT JOIN dbo.inventdim idim
      ON idim.inventdimid COLLATE DATABASE_DEFAULT = it.inventdimid COLLATE DATABASE_DEFAULT
     AND idim.dataareaid = it.dataareaid AND ISNULL(idim.IsDelete,0)=0
LEFT JOIN dbo.inventjournaltable jt
      ON jt.journalid COLLATE DATABASE_DEFAULT = ito.referenceid COLLATE DATABASE_DEFAULT
     AND jt.dataareaid = it.dataareaid AND ISNULL(jt.IsDelete,0)=0
LEFT JOIN dbo.inventlocation il
      ON il.inventlocationid COLLATE DATABASE_DEFAULT = idim.inventlocationid COLLATE DATABASE_DEFAULT
     AND il.dataareaid = it.dataareaid AND ISNULL(il.IsDelete,0)=0
WHERE it.dataareaid='1001' AND ISNULL(it.IsDelete,0)=0
ORDER BY v.accountingdate, it.voucherphysical, it.itemid;
