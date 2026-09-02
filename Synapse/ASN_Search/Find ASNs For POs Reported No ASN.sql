/*  Find the ASN(s) for a list of POs that WM/receiving reports as "No ASN".
    Source: D365 Synapse serverless (ps-prod).

    Five places an inbound vendor ASN can be for a PO. Check ALL of them --
    an ASN that was REJECTED never becomes an arrival journal, so looking only
    at wmsjournaltable will wrongly report "no ASN exists".

      1. pacasncartondata   - the raw inbound ASN carton detail (asnid + purchid direct)
      2. pacasnerrortable   - ASNs REJECTED at validation; the ASN number lives here and nowhere else
      3. wmsjournaltable    - the accepted ASN => item arrival journal (ASN on the HEADER)
      4. pacallocationdataline - which ASN number IA actually allocated against
      5. purchtable/purchline - PO status, because docstate<>40 (Draft) is itself a reject reason

    GOTCHAS
      - PO off wmsjournalTRANS.inventtransrefid, ASN off wmsjournalTABLE.pacasnid, join on journalid.
        The header's own inventtransrefid is NULL on ~4% of WM ASN journals.
      - pacasnerrortable.asnqty is ONE line's qty. The true ASN total is inside errordescription.
      - A pacasnid beginning 999 is a WM-keyed MANUAL ASN, not a vendor ASN.
      - errorcode/errortype pairs seen: 19/0 qty overage vs remaining, 19/1 qty shortage vs the 5%
        tolerance, 31/7 PO not approved (Draft) when the ASN landed, 12/8 PO line cancelled,
        20/2 early shipment.
      - Inbound vendor ASNs do NOT pass through sunintmessage - don't look for them there.
*/

DECLARE @pos TABLE (purchid varchar(20));
INSERT INTO @pos (purchid) SELECT '0000763551' UNION ALL SELECT '0000763562';  -- <<< edit PO list (zero-padded to 10)

-- 1. PO status (docstate 40 = Confirmed; anything else = the ASN would be rejected 31/7)
SELECT p.purchid, MAX(h.purchstatus) purchstatus, MAX(h.documentstatus) docstatus,
       MAX(h.documentstate) docstate, MAX(h.orderaccount) vendor, COUNT(*) lines_,
       SUM(p.qtyordered) ordered, SUM(p.remainpurchphysical) open_qty,
       MAX(CAST(p.deliverydate AS date)) deliverydate
FROM purchline p
JOIN purchtable h ON h.purchid = p.purchid AND h.dataareaid = p.dataareaid AND ISNULL(h.IsDelete,0) = 0
WHERE p.dataareaid = '1001' AND ISNULL(p.IsDelete,0) = 0
  AND p.purchid IN (SELECT purchid FROM @pos)
GROUP BY p.purchid ORDER BY p.purchid;

-- 2. REJECTED ASNs - this is where a "missing" ASN normally is
SELECT purchid, asnid, asnidfull, errorcode, errortype, releasehold, senttotraverse,
       sku, itemid, colorid, sizeid, asnqty AS line_qty, store,
       createddatetime, errordescription
FROM pacasnerrortable
WHERE dataareaid = '1001' AND ISNULL(IsDelete,0) = 0
  AND purchid IN (SELECT purchid FROM @pos)
ORDER BY purchid, createddatetime;

-- 3. ACCEPTED ASNs -> item arrival journals (posted = 1 means actually received)
SELECT t.inventtransrefid AS purchid, h.pacasnid, h.journalid, h.posted,
       MAX(h.posteddatetime) posted_dt, MAX(h.journalnameid) journalnameid,
       COUNT(*) lines_, SUM(t.qty) qty
FROM wmsjournaltrans t
JOIN wmsjournaltable h ON h.journalid = t.journalid AND h.dataareaid = t.dataareaid AND ISNULL(h.IsDelete,0) = 0
WHERE t.dataareaid = '1001' AND ISNULL(t.IsDelete,0) = 0
  AND t.inventtransrefid IN (SELECT purchid FROM @pos)
GROUP BY t.inventtransrefid, h.pacasnid, h.journalid, h.posted
ORDER BY 1, 2, 3;

-- 4. Raw inbound ASN carton detail. wmsenttowm = 0 means D365 never forwarded the ASN to WM
SELECT purchid, asnid, MIN(asncreateddt) asn_dt, MAX(warehouse) warehouse,
       COUNT(*) lines_, COUNT(DISTINCT cartonnumber) cartons,
       SUM(cartonqty) qty, MAX(wmsenttowm) sent_to_wm, MAX(vendor) vendor
FROM pacasncartondata
WHERE dataareaid = '1001' AND ISNULL(IsDelete,0) = 0
  AND purchid IN (SELECT purchid FROM @pos)
GROUP BY purchid, asnid ORDER BY 1, 2;

-- 5. Which ASN number IA allocated against (differs from the receipt ASN in a key-mismatch case)
SELECT po, asnid, COUNT(*) lines_, SUM(allocatedquantity) alloc_qty,
       COUNT(DISTINCT receivernumber) receivers, MAX(receivernumber) receiver,
       MIN(createddatetime) first_dt
FROM pacallocationdataline
WHERE po IN (SELECT purchid FROM @pos)
GROUP BY po, asnid ORDER BY 1, 2;
