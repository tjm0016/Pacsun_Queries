/* Bamboo Rose (BBR) Purchase Order Worksheet source query (MicroStrategy), schema pacsun_prod.
   2026-09-16: the Factory Name column (column 41) now shows the factory number before the name,
   e.g. '24210001 - PROTRADE GARMENTS'. Column count and order are unchanged, so the MicroStrategy
   column mapping does not change. Column 72 (offer.factory) still returns the number on its own.
   Factory number = 5-digit vendor + 3-digit factory; the last 3 digits are the D365 factory ID
   (pacVendFactory vendor 24210 / factory 001) whenever D365 has that factory set up. */
SELECT DISTINCT
    OFFER.SUPPLIER
   , OFFER.OFFER_NO
   , quote.memo1
   , quote.memo2
   , quote.memo5
   , quote.memo4
   , quote.freetext
   , quote_anc.numbr3 AS Split_Retail_Quantity
   , quote_anc.numbr4 AS Split_Retail_Price
   , OFFER.PAYMENT_TERMS
   , OFFER.STATUS_02
   , OFFER.PACK_TYPE
   , OFFER.TRANS_MODE
   , OFFER.MEMO4
   , VENDOR.PARTY_NAME
   , VENDOR.EDI_IND
   , QUOTE_EXT.PRODMGR
   , QUOTE.BUYER
   , SELL_CHANNEL_FLOW.DATE1
   , SELL_CHANNEL_FLOW.DATE3
   , QUOTE.BRAND
   , QUOTE.STATUS_04
   , QUOTE.STATUS_05
   , QUOTE.DEPT
   , QUOTE.CLASS
   , QUOTE.ITEM_NO
   , QUOTE.DESCRIPTION
   , QUOTE.REF_NO
   , QUOTE.OWNER
   , QUOTE.REQUEST_NO
   , QUOTE.STATUS_06
   , QUOTE.CONTENT_2
   , QUOTE.DIVISION
   , QUOTE.TICKET_TYPE
   , SELL_CHANNEL_FLOW.DATE2
   , SELL_CHANNEL_D.ALLOC_BY_3
   , PS_COLOR.COLOR_NAME
   , SELL_CHANNEL_D.ALT_DESC1
   , SIZE_D.SIZE_CODE
   , SIZE_D.SHIP_PACK
   ,
   CASE
   WHEN OFFER.FACTORY IS NULL
   THEN
      'NO FACTORY ENTERED ON OFFER'
   ELSE
      (
         CASE
         WHEN FACTORY.PARTY_NAME IS NULL
         THEN
            'FACTORY ID ' || OFFER.FACTORY || ' NOT VALID'
         ELSE
            OFFER.FACTORY || ' - ' || FACTORY.PARTY_NAME END) END -- factory number + name
   , PORT.DESCRIPTION
   , PS_COUNTRY_COO.DESCRIPTION
   , PS_COUNTRY_COE.DESCRIPTION
   , SIZE_H.MATCH_02
   , SELL_CHANNEL_FLOW.PLAN_ID
   , SUBSTR(REPLACE(REPLACE(PS_QUOTE_A_NOTES_VW.TEXT, CHR(10), '. '), CHR(13),'.'), 1, 500)
   , PS_OFFER_A_NOTES_VW.TEXT
   , PS_PARTY_A_NOTES_VW.TEXT
   , (OFFER.OFFER_PRICE+OFFER_ANC.numbr5)
   , QUOTE.RESELL_PRICE
   , OFFER.RESELL_PRICE
   , OFFER.OFFER_CALC_COST
   , SIZE_D.ALLOC_QTY
   , SIZE_D.PLAN_PCT_RATIO
   ,
   CASE
   WHEN OFFER.DELIVERY_TERMS = 'DDP'
   THEN
      OFFER.OFFER_CALC_COST
   ELSE
      0 END
   ,
   CASE
   WHEN OFFER.DELIVERY_TERMS = 'DDP'
   THEN
      OFFER.OFFER_CALC_COST
   ELSE
      0 END
   ,
   CASE
   WHEN OFFER.SUPPLIER IN ('21482'
                           , '21847'
                           , '10368'
                           , '10369'
                           , '10622'
                           , '10623'
                           , '17737'
                           , '19859'
                           , '19898'
                           , '44346'
                           , '25050'
                           , '45464')
   THEN
      (
         CASE
         WHEN cost_d.rate IS NOT NULL
         THEN
            COST_D.RATE/100
         ELSE
            0 END)
   ELSE
      (
         CASE
         WHEN PS_OFFER_A_COST_D_COMMISSION_VW.RATE IS NOT NULL
         THEN
            PS_OFFER_A_COST_D_COMMISSION_VW.RATE/100
         ELSE
            0 END) END
   ,
   CASE
   WHEN SIZE_D.SHIP_PACK = 'PPK'
   THEN
      SIZE_D.ALLOC_QTY
   ELSE
      0 END
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   , ' '
   ,
   CASE
   WHEN sell_channel_flow.memo2 IS NULL
      OR ltrim(RTRIM(sell_channel_flow.memo2)) = ''
   THEN
      QUOTE.FINAL_DEST
   ELSE
      sell_channel_flow.memo2 END
   , sell_channel_flow.BEGIN_DATE
   , offer.factory
   , QUOTE.STATUS_01
   , offer_anc.numbr3
   , quote.resell_price
   , vendor.party_www_url
   , quote.floor_set_id || ' ' || ps_season.DESCRIPTION
   , offer.other_party
   ,
   CASE
   WHEN offer.other_party IS NULL
   THEN
      'NO SUBCONTRACTOR ENTERED ON OFFER'
   ELSE
      (
         CASE
         WHEN other_party.party_name IS NULL
         THEN
            'SUBCONTRACTOR ID ' || offer.other_party || ' NOT VALID'
         ELSE
            other_party.party_name END) END
   , sell_channel_flow.memo1
   , sell_channel_d.alloc_by_3
   , offer.offer_price
   , cost_d_duty.amount
   , current_database ()
   , quote.owned_price
   , quote.hts_no
   , quote_anc.alt_desc2 AS   Customs_Description
   , quote.memo6 AS           Licensed
   , COST_D_ROYALTY.amount AS royalty
   ,
   CASE
   WHEN quote.memo6 IS NULL
   THEN
      1
   ELSE
      0 END
   , ps_colorway_vw.alt_desc1 colorway_name -- colorway
FROM
   ((((((((((((((((((((((( (pacsun_prod.QUOTE QUOTE
INNER JOIN
   pacsun_prod.OFFER OFFER
ON
   (
      QUOTE.OWNER=OFFER.OWNER)
   AND (
      QUOTE.REQUEST_NO=OFFER.REQUEST_NO))
INNER JOIN
   pacsun_prod.QUOTE_A QUOTE_A_SELL_CHANNEL
ON
   (
      QUOTE.OWNER=QUOTE_A_SELL_CHANNEL.OWNER)
   AND (
      QUOTE.REQUEST_NO=QUOTE_A_SELL_CHANNEL.REQUEST_NO))
INNER JOIN
   pacsun_prod.QUOTE_ANC QUOTE_ANC
ON
   (
      QUOTE.REQUEST_NO=QUOTE_ANC.REQUEST_NO)
   AND (
      QUOTE.OWNER=QUOTE_ANC.OWNER))
LEFT OUTER JOIN
   pacsun_prod.PS_QUOTE_A_NOTES_VW PS_QUOTE_A_NOTES_VW
ON
   (
      QUOTE.OWNER=PS_QUOTE_A_NOTES_VW.OWNER)
   AND (
      QUOTE.REQUEST_NO=PS_QUOTE_A_NOTES_VW.REQUEST_NO)
LEFT OUTER JOIN
   pacsun_prod.QUOTE_EXT QUOTE_EXT
ON
   QUOTE.REQUEST_NO = QUOTE_EXT.REQUEST_NO)
INNER JOIN
   pacsun_prod.OFFER_ANC OFFER_ANC
ON
   (
      (
         OFFER.OWNER=OFFER_ANC.OWNER)
      AND (
         OFFER.OFFER_NO=OFFER_ANC.OFFER_NO))
   AND (
      OFFER.REQUEST_NO=OFFER_ANC.REQUEST_NO))
LEFT OUTER JOIN
   pacsun_prod.PARTY FACTORY
ON
   OFFER.FACTORY=FACTORY.PARTY_ID)
LEFT OUTER JOIN
   pacsun_prod.PORT PORT
ON
   OFFER.lading_point=PORT.CODE)
LEFT OUTER JOIN
   pacsun_prod.COUNTRY PS_COUNTRY_COO
ON
   OFFER.ORIGIN_CNTRY=PS_COUNTRY_COO.CODE)
LEFT OUTER JOIN
   pacsun_prod.COUNTRY PS_COUNTRY_COE
ON
   OFFER.STATUS_03=PS_COUNTRY_COE.CODE)
LEFT OUTER JOIN
   pacsun_prod.PS_OFFER_A_COST_D_COMMISSION_VW PS_OFFER_A_COST_D_COMMISSION_VW
ON
   OFFER.OFFER_NO=PS_OFFER_A_COST_D_COMMISSION_VW.OFFER_NO)
LEFT OUTER JOIN
   pacsun_prod.OFFER_A OFFER_A
ON
   OFFER.OFFER_NO         =OFFER_A.OFFER_NO
   AND OFFER.REQUEST_NO   = OFFER_A.REQUEST_NO
   AND OFFER.OWNER        = OFFER_A.OWNER
   AND OFFER_A.ASSOC_NAME = 'COST' )
LEFT OUTER JOIN
   pacsun_prod.COST_D COST_D
ON
   OFFER_A.ASSOC_ID            = COST_D.ASSOC_ID
   AND COST_D.EXPENSE_CODE     = 'HDL'
   AND COST_D.EXPENSE_CATEGORY = 'MISC' )
LEFT OUTER JOIN
   pacsun_prod.cost_d COST_D_DUTY
ON
   OFFER_A.ASSOC_ID             = COST_D_DUTY.ASSOC_ID
   AND COST_D_DUTY.EXPENSE_CODE = 'DTY')
LEFT OUTER JOIN
   pacsun_prod.PS_OFFER_A_NOTES_VW PS_OFFER_A_NOTES_VW
ON
   OFFER.OFFER_NO=PS_OFFER_A_NOTES_VW.OFFER_NO)
LEFT OUTER JOIN
   pacsun_prod.PS_PARTY_A_NOTES_VW PS_PARTY_A_NOTES_VW
ON
   OFFER.SUPPLIER=PS_PARTY_A_NOTES_VW.PARTY_ID)
LEFT OUTER JOIN
   pacsun_prod.PARTY VENDOR
ON
   OFFER.SUPPLIER=VENDOR.PARTY_ID)
INNER JOIN
   pacsun_prod.SELL_CHANNEL_H SELL_CHANNEL_H
ON
   QUOTE_A_SELL_CHANNEL.ASSOC_ID=SELL_CHANNEL_H.ASSOC_ID)
INNER JOIN
   pacsun_prod.SELL_CHANNEL_FLOW SELL_CHANNEL_FLOW
ON
   SELL_CHANNEL_H.ASSOC_ID=SELL_CHANNEL_FLOW.ASSOC_ID)
INNER JOIN
   pacsun_prod.SELL_CHANNEL_D SELL_CHANNEL_D
ON
   (
      SELL_CHANNEL_FLOW.ASSOC_ID=SELL_CHANNEL_D.ASSOC_ID)
   AND (
      SELL_CHANNEL_FLOW.PLAN_ID=SELL_CHANNEL_D.ALLOC_BY_2))
INNER JOIN
   pacsun_prod.SELL_CHANNEL_D_A SELL_CHANNEL_D_A
ON
   (
      SELL_CHANNEL_D.ASSOC_ID=SELL_CHANNEL_D_A.PARENT_ASSOC_ID)
   AND (
      SELL_CHANNEL_D.ROW_NO=SELL_CHANNEL_D_A.ROW_NO))
LEFT OUTER JOIN
   pacsun_prod.COLOR_CODES PS_COLOR
ON
   SELL_CHANNEL_D.ALLOC_BY_3=PS_COLOR.COLOR_CODE)
INNER JOIN
   pacsun_prod.SIZE_H SIZE_H
ON
   SELL_CHANNEL_D_A.ASSOC_ID=SIZE_H.ASSOC_ID)
INNER JOIN
   pacsun_prod.SIZE_B SIZE_B
ON
   SIZE_H.ASSOC_ID=SIZE_B.ASSOC_ID)
INNER JOIN
   pacsun_prod.SIZE_D SIZE_D
ON
   (
      SIZE_B.ROW_NO=SIZE_D.ROW_NO)
   AND (
      SIZE_B.ASSOC_ID=SIZE_D.ASSOC_ID))
LEFT OUTER JOIN
   pacsun_prod.floor_set_id ps_season
ON
   quote.floor_set_id = ps_season.code
LEFT OUTER JOIN
   pacsun_prod.party other_party
ON
   offer.other_party = other_party.party_id
LEFT OUTER JOIN
   pacsun_prod.COST_D COST_D_ROYALTY
ON
   OFFER_A.ASSOC_ID             = COST_D_ROYALTY.ASSOC_ID
AND COST_D_ROYALTY.EXPENSE_CODE = 'RL'
   -- Ahmed Modification
LEFT OUTER JOIN
   (
      SELECT
         c.colorway_name
         , c.color_code
         , b.request_no
         , c.alt_desc1
      FROM
         pacsun_prod.quote_a b
         , pacsun_prod.colorway_h c
      WHERE
         b.assoc_id    = c.assoc_id
      AND b.assoc_name = 'COLORWAYS' ) ps_colorway_vw
ON
   (
      quote.request_no = ps_colorway_vw.REQUEST_NO)
   -- End Ahmend modification
WHERE
   (
      quote.set_ind <> 'P'
      OR (
         quote.set_ind    = 'P'
         AND offer.status = 'CFM'))
AND QUOTE_A_SELL_CHANNEL.ASSOC_NAME='SELL_CHANNEL'
AND SELL_CHANNEL_D_A.ASSOC_NAME    ='SIZE'
AND SELL_CHANNEL_H.ASSOC_ID        =SELL_CHANNEL_D.ASSOC_ID
AND SIZE_D.ALLOC_QTY               >0
AND sell_channel_d.alloc_amt       >0
AND sell_channel_d.ALLOC_BY_3      = ps_colorway_vw.color_code -- Ahmed Added
AND CAST(offer.offer_no AS INTEGER) IN (31512)
