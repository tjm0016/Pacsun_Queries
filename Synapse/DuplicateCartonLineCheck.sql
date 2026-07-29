-- Duplicate carton-line check, last 2 days (rolling, UTC)
-- Detects the WM O4 reprocessing defect (July 2026 incident): a re-run batch appends the
-- whole O4 line set a second time into paccartontransferline, and receive-by-exception
-- then posts the doubled expectation as a doubled receipt.
--
-- Signature: paccartontransferline count >= 2x the O4 message line count for the carton.
-- Benign same-SKU-split cartons pass (the O4 file also has 2 lines); only true
-- re-processing trips this. ZERO ROWS = CLEAN.
--
-- Run against prod Synapse serverless (dataverse_psprod...). All datetimes UTC.
-- Widen the window by changing the two DATEADD(day, -2, ...) filters.
WITH o4 AS (
  SELECT TRY_CAST(lm.o4casn AS bigint) AS cn,
         MIN(sm.messageid)             AS o4_file,
         COUNT(*)                      AS o4_lines
  FROM pacwminvoicecartonlinemessage lm
  JOIN sunintmessage sm ON sm.recid = lm.message
  WHERE lm.createddatetime >= DATEADD(day, -2, GETUTCDATE())
  GROUP BY TRY_CAST(lm.o4casn AS bigint)
),
xf AS (
  SELECT cartonnumber,
         TRY_CAST(cartonnumber AS bigint) AS cn,
         COUNT(*)                         AS xfer_lines,
         SUM(receivedquantity)            AS recv_units
  FROM paccartontransferline
  WHERE createddatetime >= DATEADD(day, -2, GETUTCDATE())
  GROUP BY cartonnumber
),
h AS (
  SELECT TRY_CAST(o3casn AS bigint) AS cn,
         SUM(TRY_CAST(o3tqty AS bigint)) / 10000 AS true_ship
  FROM pacwminvoicecartonheadermessage
  GROUP BY TRY_CAST(o3casn AS bigint)
)
SELECT o4.o4_file,
       x.cartonnumber,
       th.fromwh, th.towh,
       CASE th.cartonstatus WHEN 0 THEN 'CREATED' WHEN 1 THEN 'ACKED'
            WHEN 2 THEN 'IN TRANSIT' WHEN 4 THEN 'RECEIVED'
            ELSE CONCAT('S', th.cartonstatus) END AS status_label,
       h.true_ship,
       x.recv_units,
       (x.recv_units - h.true_ship) AS over_units,
       o4.o4_lines,
       x.xfer_lines,
       th.receivebyexception,
       CONVERT(varchar(19), CAST(th.receiveddatetime AT TIME ZONE 'UTC'
               AT TIME ZONE 'Pacific Standard Time' AS datetime2), 120) AS received_pst
FROM xf x
JOIN o4 ON o4.cn = x.cn
LEFT JOIN h ON h.cn = x.cn        -- LEFT: catch lines-first cartons whose O3 hasn't landed
JOIN paccartontransferheader th ON th.cartonnumber = x.cartonnumber
WHERE x.xfer_lines >= 2 * o4.o4_lines
ORDER BY o4.o4_file, x.cartonnumber;
