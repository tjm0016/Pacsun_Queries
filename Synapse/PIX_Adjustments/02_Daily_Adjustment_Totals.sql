/*
    Daily totals for each mapped WM PIX DC inventory adjustment.
    Source: pacwmpixmessage (D365 Synapse, dataverse_psprod...).

    Grain: one row per transaction date x Type x Code x Action Code.
      - txn_date  : RIGHT(pxdcr,8) = YYYYMMDD (pxdcr is a leading-zero + YYYYMMDD created date)
      - txn_count : number of PIX messages
      - units_raw : SUM(pxinva); divide by 10000 for units (see note below)

    Filter: restricted to the Type/Code pairs that appear in the mapping table (see
    01_Mapped_Adjustments.sql). Post-filter to the exact mapped Type/Code/AC combos after
    running (some AC values under these pairs are not mapped). Join the result to the PIX
    2014 matrix (Type/Code/AC) for the English Transaction Code / Action Code descriptions.

    NOTE on units: pxinva scale is either /10000 or /1000 (2014 design docs disagree).
    Transaction counts are exact regardless. Optional date window on RIGHT(pxdcr,8).
*/
SELECT
    RIGHT(pxdcr,8)                       AS txn_date,           -- YYYYMMDD
    pxtxtp                               AS pix_type,
    pxtxcd                               AS pix_code,
    LTRIM(RTRIM(ISNULL(pxaccd,'')))      AS pix_action_code,
    COUNT(*)                             AS txn_count,
    SUM(TRY_CAST(pxinva AS bigint))      AS units_raw           -- /10000 for units
FROM pacwmpixmessage
WHERE pxdcr IS NOT NULL
  AND pxdcr <> '000000000'
  -- AND RIGHT(pxdcr,8) BETWEEN '20260614' AND '20260713'       -- optional date window
  AND (
        (pxtxtp = '300' AND pxtxcd IN ('01','02','04'))
     OR (pxtxtp = '604' AND pxtxcd = '02')
     OR (pxtxtp = '606' AND pxtxcd IN ('02','04','06','13'))
     OR (pxtxtp = '608' AND pxtxcd IN ('12','14'))
     OR (pxtxtp = '901' AND pxtxcd = '01')
      )
GROUP BY RIGHT(pxdcr,8), pxtxtp, pxtxcd, LTRIM(RTRIM(ISNULL(pxaccd,'')))
ORDER BY txn_date, pix_type, pix_code, pix_action_code;
