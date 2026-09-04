/* ============================================================================
   PO arrival-delay trace: appointment date vs VI date vs expected receipt date
   ----------------------------------------------------------------------------
   Connection : D365-Production (Synapse serverless, dataverse_psprod...)
   Purpose    : For a list of POs, lay out every inbound date anchor and show
                where the delay actually is.

   Date anchors and where they live
     Expected receipt date : purchline.deliverydate / purchtable.deliverydate
                             (Snowflake IP_PO_EXP_DEL_DATE is the 100%-populated twin)
     Appointment date      : wmsjournaltable.pacappointmentdate  -- SEE WARNING
     VI date               : pacpotrackingdata.eta  (only ~15% of POs have a row;
                             a row existing == the PO is "on VI")
     ASN into D365         : pacasncartondata.SinkCreatedOn vs asncreateddt
     Actual receipt        : vendpackingsliptrans (origpurchid!) / posted ARRIVAL journal

   *** WARNING: pacappointmentdate is only a REAL appointment when the time-of-day
   *** is a slot time (06:00 dominates). A 04:44 or 00:00 stamp is a system default
   *** equal to the date the journal was created -- it is NOT a dock appointment.
   *** Step 6 proves this. Never compute an "appointment delay" off 04:44 rows.

   Manual ASNs (pacasnid prefix 999, journalid suffix -617-03-01-<PO>-CreateManualASN)
   are a WM expectation record, not a receipt. The real receipt arrives later on a
   separate 606-03 journal. If no 606-03 PIX exists (step 5), WM never receipted it.
   ============================================================================ */

/* ---- 1. PO header ------------------------------------------------------- */
SELECT p.purchid, p.purchstatus, p.documentstatus, p.documentstate, p.orderaccount,
       p.deliverydate AS expected_receipt, p.createddatetime, p.SinkCreatedOn
FROM purchtable p
WHERE p.dataareaid = '1001' AND ISNULL(p.IsDelete,0) = 0
  AND p.purchid COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
ORDER BY p.purchid;

/* ---- 2. VI date (pacpotrackingdata) -- a row existing == "on VI" -------- */
/* TRY_CAST handles both the padded and unpadded purchid formats in this table */
SELECT purchid, eta AS vi_date, handoverdate, SinkCreatedOn, SinkModifiedOn
FROM pacpotrackingdata
WHERE TRY_CAST(purchid AS bigint) IN (765313, 1307126)
ORDER BY purchid;

/* ---- 3. Arrival journals: appointment / arrival / posted ---------------- */
/* PO off the LINES, ASN + dates off the HEADER, join on journalid.
   wmsjournaltable.inventtransrefid is NULL on ~4% of WM ASN journals. */
SELECT t.inventtransrefid AS purchid, h.journalid, h.pacasnid, h.posted,
       h.pacappointmentdate, FORMAT(h.pacappointmentdate,'HH:mm') AS appt_time,
       h.pacarrivaldate, h.posteddatetime, h.SinkCreatedOn AS hdr_sink,
       SUM(t.qty) AS qty, COUNT(*) AS lines_cnt,
       CASE WHEN h.journalid COLLATE DATABASE_DEFAULT LIKE '%CreateManualASN%'
              THEN 'manual 617 expectation, never posts'
            WHEN h.journalid COLLATE DATABASE_DEFAULT LIKE '%ASNReceipt%'
              THEN 'PIX 606-03 receipt'
            ELSE 'bare pre-advice, MAO or vendor ASN' END AS journal_kind
FROM wmsjournaltrans t
JOIN wmsjournaltable h
  ON  h.journalid   COLLATE DATABASE_DEFAULT = t.journalid   COLLATE DATABASE_DEFAULT
  AND h.dataareaid  COLLATE DATABASE_DEFAULT = t.dataareaid  COLLATE DATABASE_DEFAULT
  AND ISNULL(h.IsDelete,0) = 0
WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0
  AND t.inventtransrefid COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY t.inventtransrefid, h.journalid, h.pacasnid, h.posted, h.pacappointmentdate,
         h.pacarrivaldate, h.posteddatetime, h.SinkCreatedOn
ORDER BY purchid, h.pacasnid;

/* ---- 4a. Ordered vs open ------------------------------------------------ */
SELECT purchid, COUNT(*) AS lines_cnt, SUM(qtyordered) AS ordered,
       SUM(remainpurchphysical) AS open_units, MIN(deliverydate) AS expected_receipt,
       MAX(modifieddatetime) AS last_line_change
FROM purchline
WHERE dataareaid = '1001' AND ISNULL(IsDelete,0) = 0 AND isdeleted = 0
  AND purchid COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY purchid ORDER BY purchid;

/* ---- 4b. Posted product receipts (origpurchid, NOT purchid) ------------- */
SELECT origpurchid AS purchid, packingslipid, MIN(deliverydate) AS pslip_date,
       SUM(qty) AS rcvd_qty, COUNT(*) AS lines_cnt
FROM vendpackingsliptrans
WHERE dataareaid = '1001' AND ISNULL(IsDelete,0) = 0
  AND origpurchid COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY origpurchid, packingslipid ORDER BY purchid, pslip_date;

/* ---- 4c. Vendor ASN cartons -------------------------------------------- */
/* asncreateddt vs SinkCreatedOn = how long the vendor ASN took to reach D365.
   No rows at all => there is no vendor ASN, only a WM manual 999 ASN. */
SELECT purchid, asnid, COUNT(DISTINCT cartonnumber) AS cartons, SUM(cartonqty) AS units,
       MIN(asncreateddt) AS asn_created, MIN(poshipdate) AS po_ship_date,
       MIN(SinkCreatedOn) AS asn_into_d365, MAX(wmsenttowm) AS sent_to_wm
FROM pacasncartondata
WHERE ISNULL(IsDelete,0) = 0
  AND purchid COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY purchid, asnid ORDER BY purchid, asnid;

/* ---- 4d. Allocation ---------------------------------------------------- */
SELECT po AS purchid, asnid, COUNT(*) AS lines_cnt, SUM(allocatedquantity) AS alloc_qty,
       MIN(createddatetime) AS allocated_at, COUNT(DISTINCT receivernumber) AS receivers
FROM pacallocationdataline
WHERE ISNULL(IsDelete,0) = 0
  AND po COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY po, asnid ORDER BY purchid, asnid;

/* ---- 5. Did WM ever send a RECEIPT? 617 = expectation, 606-03 = receipt -- */
/* All rows at messagestatus 40 with no 606-03 => WM never receipted the goods.
   That is a DC / vendor problem, not a stuck D365 integration. */
SELECT p.pxpon, p.pxtxtp AS type, p.pxtxcd AS code, p.pxaccd AS action_code, p.pxshmt AS asn,
       COUNT(*) AS msgs, MIN(p.pxdcr) AS first_pxdcr, MAX(p.pxdcr) AS last_pxdcr,
       SUM(CAST(p.pxunrc AS float))/10000.0 AS units_received,
       MIN(m.messagestatus) AS min_status, MAX(m.messagestatus) AS max_status
FROM pacwmpixmessage p
LEFT JOIN sunintmessage m ON m.recid = p.message
WHERE ISNULL(p.IsDelete,0) = 0
  AND LTRIM(RTRIM(p.pxpon)) COLLATE DATABASE_DEFAULT IN ('0000765313','0001307126')
GROUP BY p.pxpon, p.pxtxtp, p.pxtxcd, p.pxaccd, p.pxshmt
ORDER BY p.pxpon, p.pxtxtp, p.pxtxcd, p.pxaccd;

/* ---- 6. PROOF that a 04:44 / 00:00 appointment stamp is an artifact ----- */
/* Measured 2026-05-01 onward:
     06:00 -> 2,398 bare journals, 100% carry a real pacarrivaldate,
              avg arrival->appt 16.8 days, only 74 equal their own create date.
     04:44 -> 1,740 bare + 306 manual; appt date == journal create date on
              1,100 and 258 of them, and avg arrival->appt is 176 days.       */
SELECT CASE WHEN h.journalid COLLATE DATABASE_DEFAULT LIKE '%CreateManualASN%'
              THEN 'manual617' ELSE 'bare_or_pix' END AS jtype,
       FORMAT(h.pacappointmentdate,'HH:mm') AS appt_time,
       COUNT(*) AS journals,
       SUM(CASE WHEN CAST(h.pacappointmentdate AS date) = CAST(h.SinkCreatedOn AS date)
                THEN 1 ELSE 0 END) AS appt_equals_journal_create_date,
       SUM(CASE WHEN h.pacarrivaldate > '1900-01-02' THEN 1 ELSE 0 END) AS has_arrival_date,
       AVG(CAST(DATEDIFF(day, h.pacarrivaldate, h.pacappointmentdate) AS float)) AS avg_arrival_to_appt
FROM wmsjournaltable h
WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0 AND h.journalnameid = 'ARRIVAL'
  AND h.pacappointmentdate > '1900-01-02' AND h.SinkCreatedOn >= '2026-05-01'
GROUP BY CASE WHEN h.journalid COLLATE DATABASE_DEFAULT LIKE '%CreateManualASN%'
              THEN 'manual617' ELSE 'bare_or_pix' END,
         FORMAT(h.pacappointmentdate,'HH:mm')
ORDER BY jtype, journals DESC;

/* ---- 7. BENCHMARK: real (06:00) appointment -> first posted receipt ----- */
/* Anchor the receipt per pacasnid (see reference-dc-receipt-anchor), not per
   journal -- the pre-advice journal itself usually never posts.
   Measured 6/1-8/14/2026 over 1,295 ASNs: 0-2d 455 | 3-5d 511 | 6-10d 286 |
   11-20d 22 | early 9 | 21-40d 4 | NEVER RECEIVED 8. 96% land within 10 days. */
WITH appt AS (
  SELECT h.pacasnid COLLATE DATABASE_DEFAULT AS asn, MIN(CAST(h.pacappointmentdate AS date)) AS appt_dt
  FROM wmsjournaltable h
  WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0 AND h.journalnameid = 'ARRIVAL'
    AND FORMAT(h.pacappointmentdate,'HH:mm') = '06:00'
    AND h.pacappointmentdate >= '2026-06-01' AND h.pacappointmentdate < '2026-08-15'
  GROUP BY h.pacasnid
), rcv AS (
  SELECT h.pacasnid COLLATE DATABASE_DEFAULT AS asn, MIN(CAST(h.posteddatetime AS date)) AS first_post
  FROM wmsjournaltable h
  WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0 AND h.journalnameid = 'ARRIVAL'
    AND h.posted = 1 AND h.posteddatetime > '1901-01-01'
  GROUP BY h.pacasnid
)
SELECT a.asn, a.appt_dt, r.first_post,
       CASE WHEN r.first_post IS NULL THEN NULL
            ELSE DATEDIFF(day, a.appt_dt, r.first_post) END AS days_appt_to_receipt
FROM appt a LEFT JOIN rcv r ON r.asn = a.asn
ORDER BY days_appt_to_receipt DESC;

/* ---- 8. COHORT: one manual-ASN wave -- which POs never got received? ---- */
/* The 2026-06-02 wave was 91 manual ASNs. 36 POs (3,207 units, every one of
   them vendor 61198 FOG ESSENTIALS LLC) were still 100% open 94 days later.  */
WITH man AS (
  SELECT DISTINCT t.inventtransrefid COLLATE DATABASE_DEFAULT AS purchid
  FROM wmsjournaltable h
  JOIN wmsjournaltrans t
    ON  t.journalid  COLLATE DATABASE_DEFAULT = h.journalid  COLLATE DATABASE_DEFAULT
    AND t.dataareaid COLLATE DATABASE_DEFAULT = h.dataareaid COLLATE DATABASE_DEFAULT
    AND ISNULL(t.IsDelete,0) = 0
  WHERE h.dataareaid = '1001' AND ISNULL(h.IsDelete,0) = 0 AND h.journalnameid = 'ARRIVAL'
    AND h.journalid COLLATE DATABASE_DEFAULT LIKE '%CreateManualASN%'
    AND CAST(h.pacappointmentdate AS date) = '2026-06-02'   -- the wave date
)
SELECT pt.orderaccount, d.name AS vendor_name, m.purchid, pt.purchstatus,
       SUM(pl.qtyordered) AS ordered, SUM(pl.remainpurchphysical) AS open_units,
       MIN(pl.deliverydate) AS expected_receipt
FROM man m
JOIN purchtable pt ON pt.purchid COLLATE DATABASE_DEFAULT = m.purchid
     AND pt.dataareaid = '1001' AND ISNULL(pt.IsDelete,0) = 0
JOIN purchline pl ON pl.purchid COLLATE DATABASE_DEFAULT = m.purchid
     AND pl.dataareaid = '1001' AND ISNULL(pl.IsDelete,0) = 0 AND pl.isdeleted = 0
LEFT JOIN (SELECT DISTINCT origpurchid COLLATE DATABASE_DEFAULT AS purchid
           FROM vendpackingsliptrans WHERE dataareaid = '1001' AND ISNULL(IsDelete,0) = 0) r
       ON r.purchid = m.purchid
LEFT JOIN vendtable v ON v.accountnum COLLATE DATABASE_DEFAULT = pt.orderaccount COLLATE DATABASE_DEFAULT
     AND v.dataareaid = '1001' AND ISNULL(v.IsDelete,0) = 0
LEFT JOIN dirpartytable d ON d.recid = v.party
WHERE r.purchid IS NULL          -- never received anything at all
GROUP BY pt.orderaccount, d.name, m.purchid, pt.purchstatus
ORDER BY open_units DESC;
