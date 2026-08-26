/*==============================================================================
  ORIGINAL ordered qty for a cancelled PO, from the PO CONFIRMATION JOURNAL
  Platform : D365 Synapse serverless - ps-perf ONLY (see scope)  2026-08-26
================================================================================
  WHAT THIS SOLVES
  ----------------
  purchline zeroes qtyordered on cancel, and confirming the cancel DELETES the
  InventTransOrigin/InventTrans rows. Until now the original ordered qty only
  survived in Robling Snowflake (F_ORD_QTY).

  vendpurchorderjour changes that: it is written at each PO confirmation and is
  NEVER updated afterwards, so it retains the confirmed quantity permanently.
  VALIDATED: the 13 known cancelled POs total exactly 22,108 units here - a
  unit-for-unit match with Snowflake F_ORD_QTY, while purchline reports 0.

  HOW THE ROWS ARE SHAPED
  -----------------------
  One row per confirmation, numbered in purchorderdocnum: '<purchid>-1',
  '-2', '-3'... The FIRST is the original confirmation carrying the full qty
  and amount; a cancellation writes a LATER row with qty = 0 and amount = 0.
      0000767598-1  2026-04-13  qty 6373  amount 79662.50
      0000767598-2  2026-04-13  qty    0  amount     0.00
  Confirmations per PO: 142,542 have 1; 4,329 have 2; down to 2 POs with 9.

  !! SCOPE AND LIMITS - READ BEFORE BUILDING ON THIS !!
  * PERF ONLY. As of 2026-08-26 vendpurchorderjour exists in ps-perf and NOT
    in ps-prod. Re-check prod before promoting anything.
  * HEADER LEVEL ONLY. qty is the PO total. VendPurchOrderTrans - the
    line-level companion with per-SKU/size qty - did NOT come across, and
    neither did PurchTableVersion / PurchLineVersion / PurchLineHistory. The
    purchtableversion column here is a RecId pointing at an unsynced table.
    >> For line/size-level original qty you still need Robling F_ORD_QTY
       (Snowflake/PO_Cancelled_Qty/) or a sync of VendPurchOrderTrans.
  * HISTORY STARTS 2026-04-04 (go-live). Every migrated PO carries a '-1' row
    dated 4/4/2026 regardless of when it was really placed, so purchorderdate
    on the first row is NOT the true original order date for legacy POs.
  * createddatetime is a 1900 sentinel - date off purchorderdate.
  * 'First confirmation = original' holds for 148,702 of 149,110 POs (99.73%).
    408 POs (0.27%) have a LATER confirmation with a LARGER qty - the buy was
    increased after the first confirm. Choose deliberately:
        seq = 1   -> the ORIGINAL buy   (what was first committed)
        MAX(qty)  -> the PEAK buy       (largest ever committed)
    The query returns both so the difference is visible.
==============================================================================*/

WITH c AS (
    SELECT  j.purchid,
            j.qty,
            j.amount,
            j.purchorderdocnum,
            j.purchorderdate,
            ROW_NUMBER() OVER (PARTITION BY j.purchid
                               ORDER BY j.purchorderdate, j.recid)  AS seq,
            COUNT(*)   OVER (PARTITION BY j.purchid)                AS confirmations,
            MAX(j.qty) OVER (PARTITION BY j.purchid)                AS peak_qty
    FROM    vendpurchorderjour j
    WHERE   j.purchid IN ('0000763549','0000767598','0000767600')      -- <<< EDIT
)
SELECT  c.purchid,
        c.confirmations,
        c.qty                                   AS original_qty,      -- first confirmation
        c.peak_qty,                                                   -- largest ever confirmed
        CASE WHEN c.peak_qty > c.qty THEN 'YES - buy was increased later'
             ELSE 'no' END                      AS increased_after_first,
        c.amount                                AS original_amount,
        CAST(c.purchorderdate AS date)          AS first_confirm_date,
        c.purchorderdocnum                      AS first_confirm_doc,
        ph.purchstatus                          AS hdr_status,         -- 4 = Canceled
        ph.documentstate,                                              -- 40 = Confirmed
        ISNULL(pl.qty_now, 0)                   AS purchline_qty_now,  -- 0 once cancelled
        c.qty - ISNULL(pl.qty_now, 0)           AS qty_lost_to_cancel
FROM        c
LEFT JOIN   purchtable ph
       ON   ph.purchid = c.purchid
LEFT JOIN   (SELECT purchid, SUM(qtyordered) AS qty_now
             FROM purchline GROUP BY purchid) pl
       ON   pl.purchid = c.purchid
WHERE  c.seq = 1
ORDER BY c.purchid;
