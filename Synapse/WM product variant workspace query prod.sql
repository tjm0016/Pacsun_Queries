SELECT TOP 5 
    m.messageid, m.MessageStatus, p.*
FROM pacwmproductvariantmessage p
INNER JOIN sunIntMessage m 
    ON p.message = m.recid