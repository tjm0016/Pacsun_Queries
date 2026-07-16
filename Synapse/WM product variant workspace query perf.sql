--Test query to test table
SELECT TOP 5 *
FROM pacwmproductvariantmessage 

--Query to find the barcode, variant number, and retaill price column
SELECT STRCEX, STBRCD, STRPRC
FROM pacWMProductVariantMessage

--Query provided by Michael
SELECT TOP 5 
    m.messageid, m.MessageStatus, p.*
FROM pacwmproductvariantmessage p
INNER JOIN sunIntMessage m 
    ON p.message = m.recid