/*==============================================================================
  DAILY MONITOR -- the two OPEN PIX inventory issues
  Target : D365 F&O Synapse serverless (dataverse_psprod_*)   READ-ONLY
  Owner  : PacSun D365 Integrations
  Built  : 2026-08-11
================================================================================

WHO THIS IS FOR
  Run both queries once a day and read the [Status] column. No interpretation
  needed -- every day in the window appears as its own row, so a clean day shows
  up explicitly as "OK", not as a missing row.

  Status = OK                       -> nothing to do.
  Status = STILL BROKEN - escalate  -> the issue fired that day. Note the units
                                       and dollars, and tell the integrations team.
  Status = no journals posted       -> the integration did not run that day
                                       (weekend/holiday is normal; a weekday is NOT).

WHAT EACH ONE WATCHES

  MONITOR 1 -- PIX 620 reason code 'PS' double write-off, Retail DC 4901.
    WM sends 620/01/03 and 620/02/03 with reason code PS alongside a 300/01/08
    or 300/01/09 message that already books the same movement, so the write-off
    lands twice. Only reason code 'PS' does this -- blank reason code is
    legitimate and is shown separately so you can see it is unaffected.
    THE FIX (not yet applied): delete the two rows in
    pacwmpixtransactionmappingtable where pxtxtp='620' and pxrscd='PS'.
    Once applied, PS_DuplicateLines should go to 0 and stay there.

  MONITOR 2 -- INT-00374 re-posting the same message.
    One WM message produces 2-3 journal lines across 2-3 DIFFERENT journals,
    minutes apart. This is a runtime/retry fault, NOT a mapping problem, so it
    cannot be fixed in configuration -- it needs the integration team.
    PctAcrossMultipleJournals should always read ~100%; that is the signature
    confirming it is a re-post rather than WM sending duplicates.

HOW TO CHANGE THE WINDOW
  Both default to the last 14 days. Edit @from / @to at the top of each query.

READ THE NUMBERS WITH CARE (Monitor 2 especially)
  Counts depend on how many source messages get matched to each journal line,
  and WM transaction numbers come from a counter that eventually recycles. The
  join below guards against that by only matching messages created within a few
  days of the journal. Even so, treat Monitor 2's units and dollars as
  INDICATIVE -- the day-to-day TREND and the Status column are what matter.
  Monitor 1's numbers are exact.

RUNTIME  Monitor 1 ~13s, Monitor 2 ~28s over 14 days.
GOTCHAS  posted = 1 is mandatory (unposted journals are not real postings).
         'tran' is a T-SQL reserved word, so pacwmpxtran is aliased trn.
==============================================================================*/


/*==============================================================================
  MONITOR 1 -- PIX 620 reason code 'PS' double write-off  (warehouse 4901)
==============================================================================*/
DECLARE @from date = DATEADD(day,-14, CAST(SYSUTCDATETIME() AS date));
DECLARE @to   date = DATEADD(day,  1, CAST(SYSUTCDATETIME() AS date));

WITH days AS (                       -- every day the integration posted anything
    SELECT DISTINCT CONVERT(date, t.transdate) AS d
    FROM inventjournaltable  h
    JOIN inventjournaltrans  t ON t.journalid = h.journalid AND t.dataareaid = h.dataareaid
    WHERE t.dataareaid = '1001' AND h.posted = 1
      AND t.transdate >= @from AND t.transdate < @to
), six AS (                          -- every posted 620 line
    SELECT CONVERT(date, jl.transdate) AS d,
           CASE WHEN LTRIM(RTRIM(jl.pacwmpxrscd)) = 'PS' THEN 1 ELSE 0 END AS is_ps,
           jl.itemid, jl.qty, jl.inventdimid, jl.costamount,
           TRY_CAST(jl.pacwmpxtran AS bigint) AS trn
    FROM inventjournaltable  jt
    JOIN inventjournaltrans  jl ON jl.journalid = jt.journalid AND jl.dataareaid = jt.dataareaid
    WHERE jt.dataareaid = '1001' AND jt.posted = 1
      AND jl.pacwmpxtxtp = '620'
      AND jl.transdate >= @from AND jl.transdate < @to
      AND TRY_CAST(jl.pacwmpxtran AS bigint) IS NOT NULL
), twin AS (                         -- the 3xx line that already booked the movement
    SELECT DISTINCT TRY_CAST(jl.pacwmpxtran AS bigint) AS trn,
           jl.itemid, jl.qty, jl.inventdimid
    FROM inventjournaltable  jt
    JOIN inventjournaltrans  jl ON jl.journalid = jt.journalid AND jl.dataareaid = jt.dataareaid
    WHERE jt.dataareaid = '1001' AND jt.posted = 1
      AND jl.pacwmpxtxtp LIKE '3%'
      AND jl.transdate >= DATEADD(day,-2,@from) AND jl.transdate < @to
      AND TRY_CAST(jl.pacwmpxtran AS bigint) IS NOT NULL
), tagged AS (
    SELECT s.d, s.is_ps, s.qty, s.costamount,
           CASE WHEN t.trn IS NOT NULL THEN 1 ELSE 0 END AS is_dup
    FROM six s
    LEFT JOIN twin t
           ON  t.trn         = s.trn
           AND t.itemid      = s.itemid      COLLATE DATABASE_DEFAULT
           AND t.qty         = s.qty
           AND t.inventdimid = s.inventdimid COLLATE DATABASE_DEFAULT
)
SELECT  d.d                                                                   AS [Date],
        ISNULL(SUM(CASE WHEN g.is_ps = 1 THEN 1 ELSE 0 END), 0)                AS [PS_Lines],
        ISNULL(SUM(CASE WHEN g.is_ps = 1 AND g.is_dup = 1 THEN 1 ELSE 0 END),0) AS [PS_DuplicateLines],
        ISNULL(SUM(CASE WHEN g.is_ps = 1 AND g.is_dup = 1 THEN g.qty ELSE 0 END),0) AS [PS_DuplicateUnits],
        CAST(ISNULL(SUM(CASE WHEN g.is_ps = 1 AND g.is_dup = 1 THEN g.costamount ELSE 0 END),0)
             AS DECIMAL(18,2))                                                AS [PS_DuplicateDollars],
        ISNULL(SUM(CASE WHEN g.is_ps = 0 THEN 1 ELSE 0 END), 0)                AS [BlankReason_Lines_OK],
        CASE WHEN SUM(CASE WHEN g.is_ps = 1 AND g.is_dup = 1 THEN 1 ELSE 0 END) > 0
                  THEN 'STILL BROKEN - escalate'
             ELSE 'OK' END                                                    AS [Status]
FROM days d
LEFT JOIN tagged g ON g.d = d.d
GROUP BY d.d
ORDER BY [Date] DESC;


/*==============================================================================
  MONITOR 2 -- INT-00374 posting the same WM message more than once
==============================================================================*/
DECLARE @from2 date = DATEADD(day,-14, CAST(SYSUTCDATETIME() AS date));
DECLARE @to2   date = DATEADD(day,  1, CAST(SYSUTCDATETIME() AS date));

WITH days AS (                       -- every day the integration posted anything
    SELECT DISTINCT CONVERT(date, t.transdate) AS d
    FROM inventjournaltable  h
    JOIN inventjournaltrans  t ON t.journalid = h.journalid AND t.dataareaid = h.dataareaid
    WHERE t.dataareaid = '1001' AND h.posted = 1
      AND t.transdate >= @from2 AND t.transdate < @to2
), jl AS (                           -- what D365 BOOKED, per WM message
    SELECT CONVERT(date, t.transdate) AS d,
           LTRIM(RTRIM(t.pacwmpxtxtp)) AS txtp, LTRIM(RTRIM(t.pacwmpxtxcd)) AS txcd,
           ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),'') AS accd,
           ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),'') AS rscd,
           TRY_CAST(t.pacwmpxtran AS bigint) AS trn,
           ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'') AS casn,
           COUNT_BIG(*)                AS lines_booked,
           COUNT(DISTINCT t.journalid) AS journals,
           SUM(CAST(t.qty AS float))   AS d365_units,
           SUM(ABS(CAST(ISNULL(t.costamount,0) AS float))) AS abscost
    FROM inventjournaltable  h
    JOIN inventjournaltrans  t ON t.journalid = h.journalid AND t.dataareaid = h.dataareaid
    WHERE t.dataareaid = '1001' AND h.posted = 1
      AND t.transdate >= @from2 AND t.transdate < @to2
      AND TRY_CAST(t.pacwmpxtran AS bigint) IS NOT NULL
    GROUP BY CONVERT(date, t.transdate),
             LTRIM(RTRIM(t.pacwmpxtxtp)), LTRIM(RTRIM(t.pacwmpxtxcd)),
             ISNULL(LTRIM(RTRIM(t.pacwmpxaccd)),''), ISNULL(LTRIM(RTRIM(t.pacwmpxrscd)),''),
             TRY_CAST(t.pacwmpxtran AS bigint), ISNULL(LTRIM(RTRIM(t.pacwmpxcasn)),'')
), px AS (                           -- what WM actually SENT, same key + message date
    SELECT CONVERT(date, p.createddatetime) AS msg_d,
           LTRIM(RTRIM(p.pxtxtp)) AS txtp, LTRIM(RTRIM(p.pxtxcd)) AS txcd,
           ISNULL(LTRIM(RTRIM(p.pxaccd)),'') AS accd, ISNULL(LTRIM(RTRIM(p.pxrscd)),'') AS rscd,
           TRY_CAST(p.pxtran AS bigint) AS trn, ISNULL(LTRIM(RTRIM(p.pxcasn)),'') AS casn,
           COUNT_BIG(*) AS msgs_sent,
           SUM(CASE WHEN p.pxinat = 'S' THEN -1.0 ELSE 1.0 END
               * TRY_CAST(p.pxinva AS bigint) / 10000.0) AS wm_units
    FROM pacwmpixmessage p
    WHERE p.IsDelete IS NULL
      AND p.createddatetime >= DATEADD(day,-4,@from2)
      AND p.createddatetime <  DATEADD(day, 2,@to2)
      AND TRY_CAST(p.pxtran AS bigint) IS NOT NULL
    GROUP BY CONVERT(date, p.createddatetime),
             LTRIM(RTRIM(p.pxtxtp)), LTRIM(RTRIM(p.pxtxcd)), ISNULL(LTRIM(RTRIM(p.pxaccd)),''),
             ISNULL(LTRIM(RTRIM(p.pxrscd)),''), TRY_CAST(p.pxtran AS bigint),
             ISNULL(LTRIM(RTRIM(p.pxcasn)),'')
), bad AS (                          -- more lines booked AND more units than WM sent
    SELECT j.d, j.lines_booked - p.msgs_sent AS extra_lines,
           ABS(j.d365_units) - ABS(p.wm_units) AS extra_units,
           j.abscost * (j.lines_booked - p.msgs_sent) / j.lines_booked AS extra_cost,
           CASE WHEN j.journals > 1 THEN 1 ELSE 0 END AS multi_journal
    FROM jl j
    JOIN px p
      ON  p.trn  = j.trn
      AND p.casn = j.casn COLLATE DATABASE_DEFAULT
      AND p.txtp = j.txtp COLLATE DATABASE_DEFAULT
      AND p.txcd = j.txcd COLLATE DATABASE_DEFAULT
      AND p.accd = j.accd COLLATE DATABASE_DEFAULT
      AND p.rscd = j.rscd COLLATE DATABASE_DEFAULT
      /* RECYCLING GUARD: only match a message created near this journal's date.
         WM transaction numbers eventually recycle; without this, an unrelated
         old message can be counted as "already sent" and hide a real re-post. */
      AND p.msg_d BETWEEN DATEADD(day,-3, j.d) AND DATEADD(day, 1, j.d)
    WHERE j.lines_booked > p.msgs_sent
      AND ABS(j.d365_units) > ABS(p.wm_units) + 0.0001
)
SELECT  d.d                                                        AS [Date],
        ISNULL(COUNT(b.d), 0)                                      AS [RepostedMessages],
        ISNULL(SUM(b.extra_lines), 0)                              AS [ExtraJournalLines],
        CAST(ISNULL(SUM(b.extra_units), 0) AS DECIMAL(18,0))       AS [ExtraUnits],
        CAST(ISNULL(SUM(b.extra_cost),  0) AS DECIMAL(18,2))       AS [ExtraDollars],
        CASE WHEN COUNT(b.d) = 0 THEN NULL
             ELSE CAST(100.0 * SUM(b.multi_journal) / COUNT(b.d) AS DECIMAL(5,1))
        END                                                        AS [PctAcrossMultipleJournals],
        CASE WHEN COUNT(b.d) = 0 THEN 'OK'
             ELSE 'STILL BROKEN - escalate' END                    AS [Status]
FROM days d
LEFT JOIN bad b ON b.d = d.d
GROUP BY d.d
ORDER BY [Date] DESC;
