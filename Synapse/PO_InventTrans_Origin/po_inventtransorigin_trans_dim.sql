/*==============================================================================
  X++ trace  ->  Synapse T-SQL
  InventTransOrigin / InventTrans / InventDim for a PO
  Runs on ps-prod or ps-perf serverless (identical schema).   Verified 2026-08-26
================================================================================
  ORIGINAL X++ (query object 63375260):

    SELECT FIRSTFAST FORUPDATE * FROM InventTransOrigin(InventTransOrigin)
      USING INDEX InventTransIdIdx
      WHERE ((ReferenceId LIKE N'0000697060*'))
    JOIN FORUPDATE * FROM InventTrans(InventTrans)
      ON InventTransOrigin.RecId = InventTrans.InventTransOrigin
    JOIN FORUPDATE * FROM InventDim(InventDim)
      ON InventTrans.inventDimId = InventDim.inventDimId

  TRANSLATION NOTES
  -----------------
  * FIRSTFAST / FORUPDATE / USING INDEX are X++ execution hints. They have no
    T-SQL equivalent and no effect on results - drop them. (Synapse serverless
    is read-only; FORUPDATE is meaningless here.)
  * X++ wildcard is '*'; T-SQL is '%'.  N'0000697060*' -> '0000697060%'
  * X++ "JOIN" with no qualifier = INNER JOIN.
  * Synapse Link table/column names are lower-case.
  * InventDim MUST also be joined on dataareaid - inventdimid is company-scoped
    and will fan out across companies without it. The X++ kernel adds this
    automatically; T-SQL does not.
  * ReferenceCategory 3 = Purch (the PO leg).

  statusreceipt values, pinned EMPIRICALLY on 300k+ perf rows (not from the enum):
      5 = Ordered   (on order; no packing slip, no invoice)
      2 = Received  (product receipt posted; packing slip, no invoice)
      1 = Purchased (invoiced; packing slip + invoice)
      0 = None      (issue side / reversal)

  !! SCOPE WARNING - WHEN THIS RETURNS NOTHING !!
  These rows are deleted when purchline.qtyordered is driven to 0. Measured
  across all 268,704 perf PO lines:
      qtyordered > 0  -> 260,087 of 260,764 lines have InventTransOrigin+Trans
      qtyordered = 0  -> 80 of 7,940 lines (1.2%) - orphaned statusreceipt=5
                         rows only, 1,672 units. Not a usable source.
  The trigger is qty=0, NOT the status. So:
    - HEADER-cancelled PO whose lines were never zeroed (purchtable.purchstatus=4
      but purchline.purchstatus=1 and qtyordered>0) -> rows SURVIVE, and this
      query returns the original qty. This is the 0000697060 case: header
      Canceled, 4 lines still open, 10 units intact in both purchline and
      InventTrans.
    - Truly LINE-cancelled PO (purchline.purchstatus=4 AND qtyordered=0)
      -> InventTransOrigin and InventTrans are both GONE. Original ordered qty
      must come from Robling Snowflake F_ORD_QTY instead
      (see Snowflake/PO_Cancelled_Qty/).
  DELETE FLAGS - READ BEFORE RELYING ON THEM (measured in perf 2026-08-26)
  ------------------------------------------------------------------------
  There are TWO different flags and they are easy to confuse:

  1. IsDelete (bit)  = the Synapse Link SINK TOMBSTONE. Present on
     inventtransorigin, inventtrans, inventdim, purchline and purchtable.
     >> It is NULL on 100% of rows - 45,773,729 inventtransorigin,
        45,843,575 inventtrans, 3,430,680 inventdim, 268,704 purchline.
        Zero rows are 1 and zero rows are even 0.
     This feed is a CURRENT-STATE snapshot: when D365 deletes a row it is
     physically removed from the base table, never tombstoned. The
     *_partitioned views do not help either (inventtransorigin_partitioned
     holds 28,568 rows, all IsDelete NULL).
     => Confirming / cancelling a PO can NEVER flip this flag to "yes" here.
        The rows simply STOP EXISTING. To observe the effect you must diff
        ROW COUNTS before and after - see po_delete_flag_probe.sql.

  >> CONFIRMING A CANCELLED PO DESTROYS THE QTY - IT DOES NOT FLAG IT.
     Retention of InventTransOrigin/InventTrans on cancelled+zeroed PO lines,
     by purchtable.documentstate (perf, 6,482 lines, 2026-08-26):
         documentstate  0 Draft      21 lines -> 13 keep rows  (61.9%)
         documentstate 10 In review  46 lines -> 32 keep rows  (69.6%)
         documentstate 30 Approved   39 lines ->  0 keep rows  ( 0.0%)
         documentstate 40 CONFIRMED 5909 lines -> 35 keep rows ( 0.6%)
     The rows are DELETED at confirm, not tombstoned. There is no flag to read.
     Worked case: PO 0000697060 was cancelled (purchstatus 4, qtyordered 0 on
     all 4 lines) but left at documentstate 0 - its InventTrans rows still
     held the original 10 units. Confirm it and they disappear.

  2. isdeleted (bigint) = the D365 APPLICATION field. Exists ONLY on
     purchline - inventtransorigin / inventtrans / inventdim do not have it.
     It IS populated: 853 lines carry isdeleted = 1 (767 at purchstatus 1,
     86 at purchstatus 4). Every one of them has qtyordered = 0, so it
     flags the line as deleted but still yields no original quantity.
     NOTE: this is the field the BI staging view mixes up with IsDelete.

==============================================================================*/

SELECT  ito.referenceid                 AS purchid,
        ito.referencecategory           AS refcat,          -- 3 = Purch
        ito.inventtransid,
        it.itemid,
        idim.inventcolorid              AS color,
        idim.inventsizeid               AS size_id,
        idim.configid,
        idim.inventsiteid               AS site,
        idim.inventlocationid           AS warehouse,
        idim.wmslocationid,
        it.qty,
        it.statusreceipt,                                   -- 5=Ordered 2=Received 1=Purchased
        it.statusissue,
        CAST(it.datephysical  AS date)  AS date_physical,
        CAST(it.datefinancial AS date)  AS date_financial,
        it.packingslipid,
        it.invoiceid,
        it.costamountposted,
        it.costamountphysical,
        ito.recid                       AS origin_recid,
        -- delete / version flags (see DELETE FLAGS note in the header)
        ito.IsDelete                    AS origin_isdelete,     -- sink tombstone: ALWAYS NULL
        it.IsDelete                     AS trans_isdelete,      -- sink tombstone: ALWAYS NULL
        idim.IsDelete                   AS dim_isdelete,        -- sink tombstone: ALWAYS NULL
        ito.sysdatastatecode            AS origin_datastate,
        it.sysdatastatecode             AS trans_datastate,
        ito.SinkModifiedOn              AS origin_sinkmodified,
        it.SinkModifiedOn               AS trans_sinkmodified,
        it.recversion                   AS trans_recversion
FROM        inventtransorigin ito
INNER JOIN  inventtrans it
        ON  it.inventtransorigin = ito.recid
INNER JOIN  inventdim idim
        ON  idim.inventdimid = it.inventdimid
       AND  idim.dataareaid  = it.dataareaid                -- required; X++ adds this implicitly
WHERE   ito.referenceid LIKE '0000697060%'                  -- <<< EDIT  (X++ '*' -> T-SQL '%')
--  AND ito.referencecategory = 3                           -- uncomment to pin to the PO leg
ORDER BY it.itemid, idim.inventsizeid, it.statusreceipt;
