/*==============================================================================
  Allocation -> Carton -> Receipt trace  (+ receipt-anchored SLA)

  ** GENERATED FILE - DO NOT EDIT BY HAND. **
  Source of truth: AllocationsPortal/shared/traceSql.js
  Regenerate:      node scripts/generate_standalone_sql.js [lookbackDays]

  The portal tab (/trace.html) runs this exact logic nightly; this standalone copy exists so the
  same numbers can be pulled ad hoc from DBeaver or the PowerShell helper.

  SLA: 36 BUSINESS hours (1.5 days) from DC receipt to outbound carton.
       Escalation tiers: LATE > 36h, BREACH > 72h, CRITICAL > 102h.
  Clock starts at MIN(wmsjournaltable.posteddatetime) per pacasnid over posted=1 journals --
  NOT at the allocation, which precedes receipt on 99.94% of lines.

  Window: last 90 days of allocations. Change it by regenerating with an argument.

  Every gotcha (the 1900-sentinel-with-a-time trap, why store must be in the join key, why
  COLLATE must NOT be used, the rejected anchor fields) is documented in traceSql.js.
==============================================================================*/


DECLARE @from    datetime2 = DATEADD(day, -90, CAST(SYSUTCDATETIME() AS datetime2));
DECLARE @ctnFrom datetime2 = DATEADD(day, -104, CAST(SYSUTCDATETIME() AS datetime2));
DECLARE @now     datetime2 = CAST(SYSUTCDATETIME() AS datetime2);


WITH alloc AS (
    SELECT  h.towh            AS store,
            l.receivernumber  AS receivernumber,
            l.itemid          AS itemid,
            l.color           AS color,
            l.size            AS size,
            MAX(l.po)                 AS po,
            MAX(l.asnid)              AS asnid,
            MAX(h.fromwh)             AS dc,
            MAX(h.externallocnumber)  AS ia_batch,
            SUM(l.allocatedquantity)  AS alloc_qty,
            MIN(l.createddatetime)    AS alloc_dt
    FROM pacallocationdataline l
    JOIN pacallocationdataheader h
      ON h.allocationnumber = l.allocationnumber
    WHERE l.createddatetime >= @from
    GROUP BY h.towh, l.receivernumber, l.itemid, l.color, l.size
),
-- Roll up to ONE ROW PER CARTON first. Two reasons this stage is not optional:
--   1. receivedquantity concentrates on a single line of a duplicated carton pair (the twin
--      stays 0), so the quantities must be summed within carton+SKU before anything else.
--   2. it makes the carton list naturally distinct -- STRING_AGG over the raw lines would
--      repeat a carton number once per line and disagree with the carton COUNT.
ctnbase AS (
    SELECT  ch.towh           AS store,
            cl.receivernumber AS receivernumber,
            cl.itemid         AS itemid,
            cl.color          AS color,
            cl.size           AS size,
            cl.cartonnumber   AS cartonnumber,
            SUM(cl.cartonquantity)     AS ctn_qty,
            SUM(cl.receivedquantity)   AS rcv_qty,
            MIN(CASE WHEN ch.shippeddatetime  >= '2000-01-01' THEN ch.shippeddatetime  END) AS first_ship_dt,
            MAX(CASE WHEN ch.receiveddatetime >= '2000-01-01' THEN ch.receiveddatetime END) AS last_rcv_dt,
            MIN(CASE WHEN cl.createddatetime  >= '2000-01-01' THEN cl.createddatetime  END) AS ctn_created_dt,
            -- "Open" = shipped but never received. The sentinel test must be < 2000, not
            -- = '1900-01-01': 13,061 RECEIVED cartons carry a 1900 date WITH a time.
            SUM(CASE WHEN ch.receiveddatetime < '2000-01-01' THEN cl.cartonquantity ELSE 0 END) AS qty_open_ctn,
            MAX(ch.receivebyexception) AS any_exception
    FROM paccartontransferline cl
    JOIN paccartontransferheader ch
      ON ch.cartonnumber = cl.cartonnumber
     AND ISNULL(ch.IsDelete,0)=0
    WHERE ISNULL(cl.IsDelete,0)=0
      AND LTRIM(RTRIM(ISNULL(cl.receivernumber,'')))<>''
      AND LTRIM(RTRIM(ISNULL(ch.towh,'')))<>''
      AND cl.createddatetime >= @ctnFrom
    GROUP BY ch.towh, cl.receivernumber, cl.itemid, cl.color, cl.size, cl.cartonnumber
),
ctn AS (
    SELECT  store, receivernumber, itemid, color, size,
            COUNT(*)                                   AS cartons,
            -- LEFT() guards the varchar(256) target column: 94.7% of lines are a single carton
            -- and the observed max is 6 (~125 chars), but a pathological line must truncate
            -- rather than fail the whole bulk load.
            LEFT(STRING_AGG(CAST(cartonnumber AS varchar(24)), ','), 256) AS carton_list,
            SUM(ctn_qty)        AS ctn_qty,
            SUM(rcv_qty)        AS rcv_qty,
            MIN(first_ship_dt)  AS first_ship_dt,
            MAX(last_rcv_dt)    AS last_rcv_dt,
            MIN(ctn_created_dt) AS ctn_created_dt,
            SUM(qty_open_ctn)   AS qty_open_ctn,
            MAX(any_exception)  AS any_exception
    FROM ctnbase
    GROUP BY store, receivernumber, itemid, color, size
),
-- The SLA clock start. posted=1 only, aggregated to the ASN (never to one journal row).
receipt_asn AS (
    SELECT  w.pacasnid,
            MIN(w.posteddatetime) AS received_at,
            MAX(w.posteddatetime) AS last_receipt_at,
            COUNT(*)              AS receipt_journals
    FROM wmsjournaltable w
    WHERE w.dataareaid = '1001'
      AND ISNULL(w.IsDelete,0) = 0
      AND w.posted = 1
      AND w.posteddatetime >= '2000-01-01'
      -- NOTE: description='Item arrival' is deliberately NOT in this predicate. It is the only
      -- value in the table (38,654 rows, one distinct value), so it filters nothing.
    GROUP BY w.pacasnid
),
-- Fallback for the ASN-key-mismatch case: the vendor ASN on the allocation never appears in
-- wmsjournaltable because WM keyed the receipt under a 999-series manual ASN instead. The
-- receipt genuinely exists, just under a different key, so recover it at PO grain.
-- The PO is only available on wmsjournaltrans -- wmsjournaltable.inventtransrefid (header) is
-- NULL on WM ASN journals and is sometimes stamped with a different PO than its own lines.
receipt_po AS (
    SELECT  t.inventtransrefid AS purchid,
            MIN(w.posteddatetime) AS received_at
    FROM wmsjournaltable w
    JOIN wmsjournaltrans  t
      ON t.journalid  = w.journalid
     AND t.dataareaid = w.dataareaid
    WHERE w.dataareaid = '1001'
      AND ISNULL(w.IsDelete,0) = 0
      AND w.posted = 1
      AND w.posteddatetime >= '2000-01-01'
      AND LEFT(w.pacasnid,3) = '999'
    GROUP BY t.inventtransrefid
),
joined AS (
    SELECT
        a.*,
        c.cartons, c.carton_list, c.ctn_qty, c.rcv_qty,
        c.first_ship_dt, c.last_rcv_dt, c.ctn_created_dt, c.qty_open_ctn, c.any_exception,
        ra.received_at     AS asn_received_at,
        ra.last_receipt_at AS asn_last_receipt_at,
        rp.received_at     AS po_received_at
    FROM alloc a
    LEFT JOIN ctn c
           ON c.store          = a.store
          AND c.receivernumber = a.receivernumber
          AND c.itemid = a.itemid AND c.color = a.color AND c.size = a.size
    LEFT JOIN receipt_asn ra
           ON ra.pacasnid = a.asnid
          AND LTRIM(RTRIM(ISNULL(a.asnid,''))) <> ''
    LEFT JOIN receipt_po rp
           ON rp.purchid = a.po
          AND LTRIM(RTRIM(ISNULL(a.asnid,''))) <> ''
          AND ra.received_at IS NULL
),
calc AS (
    SELECT j.*,
           COALESCE(j.asn_received_at, j.po_received_at) AS received_at_dc,
           -- The stop event. Prefer the real ship stamp; fall back to the carton line's create
           -- stamp for cartons predating ISS-01458, when shippeddatetime was date-only
           -- (midnight-exact share by ship month: Apr 77%, May 89%, Jun 92%, Jul 51%, Aug 0.2%).
           COALESCE(j.first_ship_dt, j.ctn_created_dt) AS first_carton_at,
           CASE WHEN j.first_ship_dt IS NOT NULL THEN 'SHIPPED'
                WHEN j.ctn_created_dt IS NOT NULL THEN 'CREATED'
                ELSE NULL END AS ship_clock_source
    FROM joined j
),
sla AS (
    SELECT c.*,
           -- Elapsed runs to the carton if there is one, otherwise to now (still running).
           COALESCE(c.first_carton_at, @now) AS stop_at,
           CASE WHEN c.received_at_dc IS NULL THEN NULL
                ELSE CAST(DATEDIFF(minute, c.received_at_dc, COALESCE(c.first_carton_at, @now)) / 60.0 AS decimal(9,2))
           END AS hours_to_carton,
           CASE WHEN c.received_at_dc IS NULL THEN NULL
                ELSE CAST((DATEDIFF(minute, c.received_at_dc, COALESCE(c.first_carton_at, @now)) - DATEDIFF(week, c.received_at_dc, COALESCE(c.first_carton_at, @now)) * 2880) / 60.0 AS decimal(9,2))
           END AS biz_hours_to_carton
    FROM calc c
),
trace AS (
SELECT
    s.po                                       AS PO,
    s.store                                    AS Store,
    s.dc                                       AS DC,
    CASE WHEN s.store IN ('4901','4902','4905') THEN 'DC' ELSE 'STORE' END AS DestType,
    s.receivernumber                           AS Receiver,
    s.itemid                                   AS ItemId,
    s.color                                    AS Color,
    s.size                                     AS Size,
    s.asnid                                    AS ASN,
    s.ia_batch                                 AS IAAllocationNumber,
    s.alloc_qty                                AS AllocatedQty,
    ISNULL(s.ctn_qty,0)                        AS CartonedQty,
    ISNULL(s.rcv_qty,0)                        AS ReceivedQty,
    s.alloc_qty - ISNULL(s.ctn_qty,0)          AS AllocGapQty,
    ISNULL(s.ctn_qty,0) - ISNULL(s.rcv_qty,0)  AS TransitGapQty,
    ISNULL(s.cartons,0)                        AS Cartons,
    s.carton_list                              AS CartonNumbers,
    ISNULL(s.qty_open_ctn,0)                   AS QtyInOpenCartons,
    DATEDIFF(day, s.alloc_dt, @now)            AS AgeDays,
    CASE
      WHEN s.ctn_qty IS NULL                     THEN 'A-NO CARTON'
      WHEN s.ctn_qty < s.alloc_qty               THEN 'B-SHORT CARTONED'
      WHEN s.ctn_qty > s.alloc_qty               THEN 'C-OVER CARTONED'
      WHEN s.rcv_qty = 0 AND s.qty_open_ctn > 0  THEN 'D-IN TRANSIT'
      WHEN s.rcv_qty < s.ctn_qty                 THEN 'E-RECEIVED SHORT'
      WHEN s.rcv_qty > s.ctn_qty                 THEN 'F-RECEIVED OVER'
      ELSE                                            'G-CLEAN'
    END                                        AS TraceStatus,
    s.any_exception                            AS ReceiveByException,

    -- ---- SLA clock ----
    CASE WHEN s.asn_received_at IS NOT NULL THEN 'ASN'
         WHEN s.po_received_at  IS NOT NULL THEN 'PO-MANUAL'
         ELSE NULL END                         AS ReceiptAnchorSource,
    DATEDIFF(hour, s.received_at_dc, s.asn_last_receipt_at) AS ReceiptSpreadHours,
    s.ship_clock_source                        AS ShipClockSource,
    s.hours_to_carton                          AS HoursToCarton,
    s.biz_hours_to_carton                      AS BusinessHoursToCarton,
    -- NULL, never 0, for every row that has no clock -- including DC-destined rows, which DO
    -- resolve a receipt anchor (their ASN posts normally) but can never produce a store carton,
    -- so their elapsed time grows forever and would otherwise register as a permanent breach.
    -- NULL is what keeps them out of BOTH sides of the attainment ratio.
    CASE WHEN s.store IN ('4901','4902','4905') THEN NULL
         WHEN s.received_at_dc IS NULL          THEN NULL
         WHEN s.biz_hours_to_carton > 36    THEN 1
         ELSE 0 END                             AS SlaBreachFlag,
    CASE WHEN s.received_at_dc IS NULL THEN DATEDIFF(day, s.alloc_dt, @now) ELSE NULL END AS AwaitingReceiptDays,
    CASE
      -- Out of the SLA population entirely.
      WHEN s.store IN ('4901','4902','4905')                THEN 'OUT OF SCOPE-DC'
      -- No clock can start.
      WHEN LTRIM(RTRIM(ISNULL(s.asnid,''))) = ''            THEN 'RESERVE-NO ASN'
      WHEN s.received_at_dc IS NULL AND s.ctn_qty IS NOT NULL THEN 'SHIPPED-RCPT NOT POSTED'
      WHEN s.received_at_dc IS NULL                         THEN 'AWAITING DC RECEIPT'
      -- Clock running or stopped.
      WHEN s.hours_to_carton < 0                            THEN 'SHIPPED AHEAD OF RCPT'
      WHEN s.biz_hours_to_carton > 102        THEN 'CRITICAL'
      WHEN s.biz_hours_to_carton > 72            THEN 'BREACH'
      WHEN s.biz_hours_to_carton > 36                   THEN 'LATE'
      WHEN s.ctn_qty IS NULL                                THEN 'RUNNING'
      ELSE                                                       'ON TIME'
    END                                        AS SlaStatus,

    CAST(s.alloc_dt AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2)                        AS AllocatedDate,
    CAST(s.received_at_dc AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2)                  AS ReceivedAtDC,
    CAST(DATEADD(hour, 48 * DATEDIFF(week, s.received_at_dc, DATEADD(hour, 36, s.received_at_dc)) + 36, s.received_at_dc) AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2) AS SlaDueAt,
    CAST(s.first_carton_at AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2)                 AS FirstCartonAt,
    CAST(s.first_ship_dt AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2)                   AS FirstShippedDate,
    CAST(s.last_rcv_dt AT TIME ZONE 'UTC' AT TIME ZONE 'Pacific Standard Time' AS datetime2)                     AS LastReceivedDate
FROM sla s
)
SELECT Store,
       SUM(AllocatedQty) AS allocated_u,
       SUM(CartonedQty)  AS cartoned_u,
       SUM(ReceivedQty)  AS received_u,
       SUM(CASE WHEN SlaBreachFlag = 1 THEN AllocatedQty ELSE 0 END) AS past_sla_u,
       SUM(CASE WHEN SlaStatus = 'CRITICAL'            THEN AllocatedQty ELSE 0 END) AS critical_u,
       SUM(CASE WHEN SlaStatus = 'BREACH'              THEN AllocatedQty ELSE 0 END) AS breach_u,
       SUM(CASE WHEN SlaStatus = 'LATE'                THEN AllocatedQty ELSE 0 END) AS late_u,
       SUM(CASE WHEN SlaStatus = 'AWAITING DC RECEIPT' THEN AllocatedQty ELSE 0 END) AS awaiting_receipt_u,
       SUM(CASE WHEN TraceStatus = 'D-IN TRANSIT'      THEN AllocatedQty ELSE 0 END) AS in_transit_u,
       -- Attainment is measured ONLY over rows that have a clock (SlaBreachFlag IS NOT NULL).
       SUM(CASE WHEN SlaBreachFlag = 0 THEN AllocatedQty ELSE 0 END) AS on_time_u,
       SUM(CASE WHEN SlaBreachFlag IS NOT NULL THEN AllocatedQty ELSE 0 END) AS measurable_u
FROM trace
WHERE DestType = 'STORE'
GROUP BY Store
ORDER BY SUM(CASE WHEN SlaBreachFlag = 1 THEN AllocatedQty ELSE 0 END) DESC;
