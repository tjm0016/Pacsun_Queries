SELECT
  (SELECT COUNT(*) FROM paccartontransferheader) AS xfer_hdr_total,
  (SELECT COUNT(*) FROM paccartontransferline)   AS xfer_line_total,
  (SELECT MAX(createddatetime) FROM paccartontransferheader) AS xfer_hdr_newest,
  (SELECT MAX(SinkModifiedOn)  FROM paccartontransferheader) AS lake_sink_newest,
  (SELECT COUNT(*) FROM paccartontransferheader th
     JOIN pacwminvoicecartonheadermessage h
       ON TRY_CAST(th.cartonnumber AS bigint)=TRY_CAST(h.o3casn AS bigint)
    WHERE RIGHT(h.o3dcr,8) BETWEEN '20260530' AND '20260704'
      AND LTRIM(RTRIM(ISNULL(h.o3shto,'')))='') AS our_cartons_in_hdr,
  (SELECT COUNT(*) FROM pacwminvoicecartonlinemessage l
     JOIN pacwminvoicecartonheadermessage h ON h.o3casn=l.o4casn
    WHERE RIGHT(h.o3dcr,8) BETWEEN '20260530' AND '20260704'
      AND LTRIM(RTRIM(ISNULL(h.o3shto,'')))='') AS our_o4_line_rows,
  (SELECT COUNT(*) FROM pacwminvoicecartonheadermessage h
    WHERE RIGHT(h.o3dcr,8) BETWEEN '20260530' AND '20260704'
      AND LTRIM(RTRIM(ISNULL(h.o3shto,'')))=''
      AND NOT EXISTS (SELECT 1 FROM pacwminvoicecartonlinemessage l WHERE l.o4casn=h.o3casn)) AS still_missing_o4;
