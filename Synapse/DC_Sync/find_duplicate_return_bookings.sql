/*
  FIND DUPLICATE RETURN BOOKINGS  (WM -> D365 PIX double-post)

  WHAT IT FINDS
  One physical e-comm return into DC 4905 is booked into D365 THREE times:
     +1 Active     rc=0 return sales-order receipt        <- the only correct booking
     +1 Lock_Code  PIX 604/02 "Returns Acknowledgement SKU Detail"   -> MOV-DCADJ
     +1 Lock_Code  PIX 606/04 "Returns: Unallocatable Inventory"     -> MOV-DCADJ
  604/02 and 606/04 are the SAME WM event: identical RMA in pacwmpxcasn and
  CONSECUTIVE pacwmpxtran numbers. Both have rows in pacwmpixtransactionmappingtable
  so INT-00374 creates a movement-journal line for each => +2 phantom units per return.
  The nightly COU-DCSYNC counting journal deletes the phantoms, which is why this is
  invisible until the sync pauses (see 7/14-7/28 outage -> the 7/29 catch-up write-off).

  Running ~90-100 journals and $47K-$120K of phantom value EVERY business day
  (verified unbroken 6/1 - 8/7/2026, weekends roll into Monday).

  FIX: drop 604/02 OR 606/04 from pacwmpixtransactionmappingtable. After the fix,
  Query 1 should return zero rows (or Query 2's dup_legs should drop to 1).

  Synapse serverless, DB dataverse_psprod_unq1fedfd537528f111a7e5000d3a5cc, dataareaid 1001.
  GOTCHA: 'tran' is a T-SQL reserved word -- alias pacwmpxtran as trn inside CTEs.
*/

DECLARE @from DATE = '2026-07-01';
DECLARE @to   DATE = '2026-08-01';

---------------------------------------------------------------------------
-- QUERY 1 -- PAIR LEVEL: one row per duplicated return.
--            This is the "find the duplicates" query. Each row = 1 physical
--            unit that got booked twice in the movement journal.
---------------------------------------------------------------------------
SELECT
    jl.journalid                                              AS journal_number,
    jl.voucher                                                AS gl_voucher,
    CONVERT(date, jl.transdate)                               AS trans_date,
    jl.itemid + '-' + dj.inventcolorid + '-' + dj.inventsizeid AS full_item_number,
    jl.itemid,
    dj.inventcolorid                                          AS color,
    dj.inventsizeid                                           AS size,
    dj.inventlocationid                                       AS warehouse,
    dj.wmslocationid                                          AS bucket,
    jl.pacwmpxcasn                                            AS rma,
    -- the two PIX messages that are really one event
    MAX(CASE WHEN jl.pacwmpxtxtp = '604' THEN jl.pacwmpxtxtp + '/' + jl.pacwmpxtxcd END) AS pix_leg_1,
    MAX(CASE WHEN jl.pacwmpxtxtp = '604' THEN jl.pacwmpxtran END)                        AS pix_tran_1,
    MAX(CASE WHEN jl.pacwmpxtxtp = '606' THEN jl.pacwmpxtxtp + '/' + jl.pacwmpxtxcd END) AS pix_leg_2,
    MAX(CASE WHEN jl.pacwmpxtxtp = '606' THEN jl.pacwmpxtran END)                        AS pix_tran_2,
    SUM(CASE WHEN jl.pacwmpxtxtp = '604' THEN jl.qty ELSE 0 END) AS qty_604_02,
    SUM(CASE WHEN jl.pacwmpxtxtp = '606' THEN jl.qty ELSE 0 END) AS qty_606_04,
    SUM(jl.qty)                                               AS units_booked,
    SUM(jl.qty) / 2.0                                         AS units_actually_returned,
    SUM(jl.qty) / 2.0                                         AS phantom_units,
    CAST(SUM(jl.costamount) / 2.0 AS DECIMAL(18,2))           AS phantom_cost
FROM inventjournaltable  jt
JOIN inventjournaltrans  jl ON jl.journalid   = jt.journalid   AND jl.dataareaid = jt.dataareaid
JOIN inventdim           dj ON dj.inventdimid = jl.inventdimid AND dj.dataareaid = jl.dataareaid
WHERE jt.dataareaid    = '1001'
  AND jt.journalnameid = 'MOV-DCADJ'
  AND jl.transdate >= @from AND jl.transdate < @to
  AND (   (jl.pacwmpxtxtp = '604' AND jl.pacwmpxtxcd = '02')
       OR (jl.pacwmpxtxtp = '606' AND jl.pacwmpxtxcd = '04') )
GROUP BY jl.journalid, jl.voucher, CONVERT(date, jl.transdate),
         jl.itemid, dj.inventcolorid, dj.inventsizeid,
         dj.inventlocationid, dj.wmslocationid, jl.pacwmpxcasn
HAVING COUNT(DISTINCT jl.pacwmpxtxtp) = 2      -- <== both legs present = duplicate
ORDER BY phantom_cost DESC, jl.journalid;


---------------------------------------------------------------------------
-- QUERY 2 -- LINE LEVEL: every individual journal line behind the duplicates.
--            Use this to eyeball the consecutive pacwmpxtran signature.
---------------------------------------------------------------------------
SELECT
    jl.journalid                                              AS journal_number,
    jl.voucher                                                AS gl_voucher,
    CONVERT(date, jl.transdate)                               AS trans_date,
    jl.itemid + '-' + dj.inventcolorid + '-' + dj.inventsizeid AS full_item_number,
    jl.pacwmpxtxtp                                            AS pix_type,
    jl.pacwmpxtxcd                                            AS pix_code,
    jl.pacwmpxaccd                                            AS pix_action_code,
    jl.pacwmpxtran                                            AS pix_tran_number,
    jl.pacwmpxcasn                                            AS rma,
    dj.inventlocationid                                       AS warehouse,
    dj.wmslocationid                                          AS bucket,
    jl.qty                                                    AS units,
    jl.costamount                                             AS cost
FROM inventjournaltable  jt
JOIN inventjournaltrans  jl ON jl.journalid   = jt.journalid   AND jl.dataareaid = jt.dataareaid
JOIN inventdim           dj ON dj.inventdimid = jl.inventdimid AND dj.dataareaid = jl.dataareaid
WHERE jt.dataareaid    = '1001'
  AND jt.journalnameid = 'MOV-DCADJ'
  AND jl.transdate >= @from AND jl.transdate < @to
  AND (   (jl.pacwmpxtxtp = '604' AND jl.pacwmpxtxcd = '02')
       OR (jl.pacwmpxtxtp = '606' AND jl.pacwmpxtxcd = '04') )
  -- narrow as needed, e.g.:
  -- AND jl.journalid = 'INV-01213678'
  -- AND jl.itemid    = '0131-61111-0020'
ORDER BY jl.journalid, jl.pacwmpxcasn, jl.pacwmpxtxtp;


---------------------------------------------------------------------------
-- QUERY 3 -- JOURNAL ROLLUP: which journals contain duplicates, and how much.
--            2,168 journals in July 2026 / 144,794 phantom units / $1,819,309.
---------------------------------------------------------------------------
SELECT
    jl.journalid                          AS journal_number,
    CONVERT(date, jl.transdate)           AS trans_date,
    CONVERT(date, jt.posteddatetime)      AS posted_date,
    jt.posted                             AS is_posted,
    COUNT(DISTINCT jl.pacwmpxcasn)        AS returns_duplicated,
    COUNT(DISTINCT jl.itemid)             AS items,
    SUM(CASE WHEN jl.pacwmpxtxtp = '604' THEN jl.qty ELSE 0 END) AS qty_604_02,
    SUM(CASE WHEN jl.pacwmpxtxtp = '606' THEN jl.qty ELSE 0 END) AS qty_606_04,
    SUM(jl.qty)                                     AS units_booked,
    CAST(SUM(jl.costamount) / 2.0 AS DECIMAL(18,2)) AS phantom_cost
FROM inventjournaltable  jt
JOIN inventjournaltrans  jl ON jl.journalid = jt.journalid AND jl.dataareaid = jt.dataareaid
WHERE jt.dataareaid    = '1001'
  AND jt.journalnameid = 'MOV-DCADJ'
  AND jl.transdate >= @from AND jl.transdate < @to
  AND (   (jl.pacwmpxtxtp = '604' AND jl.pacwmpxtxcd = '02')
       OR (jl.pacwmpxtxtp = '606' AND jl.pacwmpxtxcd = '04') )
GROUP BY jl.journalid, CONVERT(date, jl.transdate), CONVERT(date, jt.posteddatetime), jt.posted
ORDER BY units_booked DESC;


---------------------------------------------------------------------------
-- QUERY 4 -- GENERIC TWIN DETECTOR (defect #2, separate from returns):
--            any 3xx-family and 6xx-family MOV-DCADJ line sharing ONE
--            pacwmpxtran = one WM event described twice.
--            SAME-SIGNED pairs are real doubling (over/short LC/LW/MS flips
--            the 6xx leg's sign while the blank-ref 3xx twin posts plainly).
--            OFFSETTING pairs net to zero -- churn only, not a misstatement.
---------------------------------------------------------------------------
WITH ln AS (
    SELECT jl.pacwmpxtran AS trn,          -- 'tran' is reserved -- alias it
           jl.journalid, jl.itemid, jl.voucher,
           dj.inventcolorid, dj.inventsizeid,
           dj.inventlocationid AS wh,
           jl.pacwmpxtxtp, jl.pacwmpxtxcd, jl.pacwmpxaccd,
           CASE WHEN jl.pacwmpxtxtp LIKE '3%' THEN 1 ELSE 0 END AS is3,
           CASE WHEN jl.pacwmpxtxtp LIKE '6%' THEN 1 ELSE 0 END AS is6,
           jl.qty, jl.costamount
    FROM inventjournaltable jt
    JOIN inventjournaltrans jl ON jl.journalid   = jt.journalid   AND jl.dataareaid = jt.dataareaid
    JOIN inventdim          dj ON dj.inventdimid = jl.inventdimid AND dj.dataareaid = jl.dataareaid
    WHERE jt.dataareaid = '1001' AND jt.journalnameid = 'MOV-DCADJ'
      AND jl.transdate >= @from AND jl.transdate < @to
      AND jl.pacwmpxtran IS NOT NULL AND jl.pacwmpxtran <> ''
)
SELECT
    MIN(ln.journalid) AS journal_number,
    MIN(ln.voucher)   AS gl_voucher,
    ln.trn            AS pix_tran_number,
    MIN(ln.itemid) + '-' + MIN(ln.inventcolorid) + '-' + MIN(ln.inventsizeid) AS full_item_number,
    MIN(ln.wh)        AS warehouse,
    MAX(CASE WHEN ln.is3 = 1 THEN ln.pacwmpxtxtp + '/' + ln.pacwmpxtxcd + '/' + ln.pacwmpxaccd END) AS pix_leg_3xx,
    MAX(CASE WHEN ln.is6 = 1 THEN ln.pacwmpxtxtp + '/' + ln.pacwmpxtxcd + '/' + ln.pacwmpxaccd END) AS pix_leg_6xx,
    SUM(CASE WHEN ln.is3 = 1 THEN ln.qty ELSE 0 END) AS qty_3xx,
    SUM(CASE WHEN ln.is6 = 1 THEN ln.qty ELSE 0 END) AS qty_6xx,
    CASE WHEN SIGN(SUM(CASE WHEN ln.is3 = 1 THEN ln.qty ELSE 0 END))
            = SIGN(SUM(CASE WHEN ln.is6 = 1 THEN ln.qty ELSE 0 END))
         THEN 'SAME-SIGNED (doubled)' ELSE 'OFFSETTING (nets 0)' END AS pattern,
    CAST(SUM(CASE WHEN ln.is3 = 1 THEN ABS(ln.costamount) ELSE 0 END) AS DECIMAL(18,2)) AS excess_cost
FROM ln
GROUP BY ln.trn
HAVING MAX(ln.is3) = 1 AND MAX(ln.is6) = 1
   AND SUM(CASE WHEN ln.is3 = 1 THEN ln.qty ELSE 0 END) <> 0
   AND SIGN(SUM(CASE WHEN ln.is3 = 1 THEN ln.qty ELSE 0 END))
     = SIGN(SUM(CASE WHEN ln.is6 = 1 THEN ln.qty ELSE 0 END))   -- drop this line to see BOTH patterns
ORDER BY excess_cost DESC;
