/*==============================================================================
  BEFORE / AFTER PROBE - what does confirming a cancelled PO actually do?
  Run on ps-perf serverless.                                Verified 2026-08-26
================================================================================
  WHY A PROBE INSTEAD OF READING A FLAG
  -------------------------------------
  The Synapse Link sink tombstone IsDelete is NULL on 100% of rows in
  inventtransorigin (45,773,729), inventtrans (45,843,575), inventdim
  (3,430,680) and purchline (268,704). It is never written. So you CANNOT
  detect a delete by reading IsDelete - deleted rows are physically removed
  from the base tables.

  The only way to see what a confirm/cancel did is to diff ROW COUNTS and
  quantities before and after. Run this query, do the action in D365, wait for
  the Synapse sync, run it again, compare.

  WHAT THE ANSWER TURNED OUT TO BE (perf, 2026-08-26)
  ---------------------------------------------------
  Confirming a cancelled PO does NOT set IsDelete = yes. It DELETES the
  InventTransOrigin / InventTrans rows outright. Measured over 6,482
  cancelled + zeroed PO lines, grouped by purchtable.documentstate:
      0  Draft       21 lines ->  13 keep their trans rows  (61.9%)
      10 In review   46 lines ->  32 keep their trans rows  (69.6%)
      30 Approved    39 lines ->   0 keep their trans rows  ( 0.0%)
      40 CONFIRMED 5909 lines ->  35 keep their trans rows  ( 0.6%)
  So the qty is readable ONLY while the cancel is still unconfirmed.

  A row that DISAPPEARS between run 1 and run 2 was deleted in D365.
  purchline rows do NOT disappear - watch qtyordered -> 0 and isdeleted -> 1.

  TIMING: perf Synapse ran ~1 day behind on 2026-08-26 (purchline and
  inventtrans both current to 8/25). Do not read a "0 rows" second run as
  proof of deletion until the sync has actually caught up - confirm freshness
  with the last block below first.
==============================================================================*/

DECLARE @po VARCHAR(20) = '0000697060';   -- <<< EDIT

-- A) purchline: survives deletion, so read the flags directly
SELECT  'A_purchline'          AS probe,
        pl.linenumber,
        pl.qtyordered,
        pl.purchstatus,                       -- 4 = Canceled
        pl.isdeleted           AS app_isdeleted,   -- D365 field: 0/1, IS populated
        pl.IsDelete            AS sink_isdelete,   -- tombstone: always NULL
        pl.recversion,
        pl.SinkModifiedOn,
        CAST(pl.modifieddatetime AS date) AS modified
FROM    purchline pl
WHERE   pl.purchid = @po
ORDER BY pl.linenumber;

-- B) header state (purchtable has NO app-level isdeleted, only the sink flag)
SELECT  'B_purchtable' AS probe, ph.purchid,
        ph.purchstatus,                       -- 4 = Canceled
        ph.documentstate,                     -- 40 = Confirmed (change management)
        ph.IsDelete AS sink_isdelete,         -- always NULL
        ph.SinkModifiedOn
FROM    purchtable ph
WHERE   ph.purchid = @po;

-- C) THE ONE THAT MATTERS: do the origin/trans rows still exist?
--    Count going to 0 between runs = D365 deleted them.
SELECT  'C_counts' AS probe,
        (SELECT COUNT(*) FROM inventtransorigin ito
          WHERE ito.referenceid = @po)                                   AS origin_rows,
        (SELECT COUNT(*) FROM inventtransorigin ito
           JOIN inventtrans it ON it.inventtransorigin = ito.recid
          WHERE ito.referenceid = @po)                                   AS trans_rows,
        (SELECT ISNULL(SUM(it.qty),0) FROM inventtransorigin ito
           JOIN inventtrans it ON it.inventtransorigin = ito.recid
          WHERE ito.referenceid = @po)                                   AS trans_qty,
        (SELECT COUNT(*) FROM inventtransorigin ito
           JOIN inventtrans it ON it.inventtransorigin = ito.recid
          WHERE ito.referenceid = @po AND it.IsDelete = 1)               AS trans_tombstoned;
        -- trans_tombstoned will be 0 in every environment - the flag is never set

-- D) line detail, so you can see WHICH rows vanish
SELECT  'D_detail' AS probe, it.itemid, idim.inventsizeid AS size_id,
        it.qty, it.statusreceipt,              -- 5=Ordered 2=Received 1=Purchased
        it.IsDelete AS trans_isdelete, ito.IsDelete AS origin_isdelete,
        it.SinkModifiedOn
FROM        inventtransorigin ito
INNER JOIN  inventtrans it   ON it.inventtransorigin = ito.recid
INNER JOIN  inventdim   idim ON idim.inventdimid = it.inventdimid
                            AND idim.dataareaid  = it.dataareaid
WHERE   ito.referenceid = @po
ORDER BY it.itemid, idim.inventsizeid;

-- E) freshness guard - do NOT interpret run 2 until these move past your action
SELECT  'E_freshness' AS probe,
        (SELECT MAX(CAST(createddatetime AS date)) FROM purchline)   AS purchline_max_created,
        (SELECT MAX(CAST(datephysical    AS date)) FROM inventtrans) AS inventtrans_max_physical,
        (SELECT MAX(SinkModifiedOn) FROM purchline WHERE purchid = @po) AS this_po_sinkmodified;
