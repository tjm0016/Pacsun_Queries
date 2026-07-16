/*
    Mapped WM PIX -> D365 journal adjustments (the "47/48 DC Inv Adjustments").
    Source: pacwmpixtransactionmappingtable (D365 Synapse, dataverse_psprod...).
    Each row = a Type/Code/ActionCode combo that D365 posts as an inventory adjustment.
    Decode Type/Code/AC against the PIX 2014 processing matrix for the English meaning.
*/
SELECT
    pxtxtp                       AS pix_type,
    pxtxcd                       AS pix_code,
    ISNULL(pxaccd,'')            AS pix_action_code,
    reasoncode                   AS d365_reason,
    journalnameid                AS d365_journal,
    journaltype                  AS d365_journal_type
FROM pacwmpixtransactionmappingtable
WHERE (IsDelete IS NULL OR IsDelete = 0)
  AND (sysdatastatecode = 0 OR sysdatastatecode IS NULL)
ORDER BY pxtxtp, pxtxcd, pxaccd;
