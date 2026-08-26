/*==============================================================================
  LINE-LEVEL original ordered qty for a cancelled PO - purchlinehistory
  Platform : D365 Synapse serverless - ps-perf ONLY             2026-08-26
================================================================================
  THIS IS THE COMPLETE ANSWER, IN D365, AT LINE + SIZE GRAIN.

  purchline zeroes qtyordered on cancel and the InventTrans rows are deleted at
  confirm. purchlinehistory keeps the ORIGINAL qtyordered per line, with
  inventdimid so size/colour resolve through inventdim.

  VALIDATED THREE WAYS
  --------------------
  * The 13 known cancelled POs total exactly 22,108 units - matches Robling
    F_ORD_QTY to the unit, while purchline reports 0.
  * COVERAGE IS 100%: all 1,464 POs holding cancelled+zeroed lines are present.
  * PO 0000762585 reproduces the Snowflake row-version generations exactly
    (150 -> 115 -> 151 -> 115) WITH sizes, and agrees with the confirmation
    sequence in vendpurchorderjour ('-1' 150, '-2' 115, '-3' 151, '-4' 115).

  GENERATIONS - THE ONE REAL TRAP
  -------------------------------
  A revised PO stores every generation, so SUM(qtyordered) over the whole PO
  double counts (762585 sums to 531 against a 150 original / 115 live).
  104,407 lines have 1 history row; 16,377 have 2-7.
  createddatetime AND modifieddatetime are 1900 sentinels on ALL 146,076 rows,
  so they cannot order anything - RECID IS THE ONLY ORDERING KEY.
  Generations arrive as blocks of consecutive recids, so the gaps-and-islands
  trick below (recid - row_number()) isolates them. gen = 1 is the original buy.
  Cross-check gen 1's total against vendpurchorderjour '-1' qty.

  OTHER LIMITS
  ------------
  * PERF ONLY - absent from ps-prod as of 2026-08-26. Verify before promoting.
  * History starts at the 2026-04-04 go-live, same as vendpurchorderjour.
  * There is no "cancelled qty" column here either - derive it as
    original - current, exactly as on the Snowflake side.
==============================================================================*/

WITH h AS (
    SELECT  ph.purchid, ph.linenumber, ph.itemid, ph.qtyordered, ph.purchstatus,
            ph.recid, ph.inventdimid, ph.dataareaid,
            -- consecutive recids form one generation; the difference is constant per block
            ph.recid - ROW_NUMBER() OVER (PARTITION BY ph.purchid ORDER BY ph.recid) AS block_key
    FROM    purchlinehistory ph
    WHERE   ph.purchid IN ('0000762585','0000763549','0000767598')      -- <<< EDIT
), g AS (
    SELECT  h.*, DENSE_RANK() OVER (PARTITION BY h.purchid ORDER BY h.block_key) AS gen
    FROM    h
)
SELECT  g.purchid,
        g.gen,                                        -- 1 = ORIGINAL buy
        g.linenumber,
        g.itemid,
        d.inventcolorid                 AS color,
        d.inventsizeid                  AS size_id,
        d.inventlocationid              AS warehouse,
        g.qtyordered                    AS original_qty,
        SUM(g.qtyordered) OVER (PARTITION BY g.purchid, g.gen) AS gen_total_qty,
        pl.qtyordered                   AS purchline_qty_now,   -- 0 once cancelled
        g.recid
FROM        g
LEFT JOIN   inventdim d
       ON   d.inventdimid = g.inventdimid AND d.dataareaid = g.dataareaid
LEFT JOIN   purchline pl
       ON   pl.purchid = g.purchid AND pl.linenumber = g.linenumber
      AND   pl.dataareaid = g.dataareaid
-- WHERE g.gen = 1        -- uncomment for the ORIGINAL buy only
ORDER BY g.purchid, g.gen, g.linenumber;
