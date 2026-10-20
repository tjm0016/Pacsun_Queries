-- Store Card Entry Type And Auth Outcome By Day (MAO replica MySQL, default_order / default_payment)
-- For one business date: store (selling location < 4000) non-cancelled orders, non-voided card payment methods,
-- grouped by entry type, split into methods with a successful gateway response vs failed-only.
-- Used 2026-10-20 to test "pre-10/1 NFC was inflated by failed auths": failed-only Contactless is a steady ~2%
-- before and after 10/1; successful Contactless is ~79% of card-present entries on every day checked; D365
-- RetailTransactionPaymentTrans Contactless = 98-99% of MAO successful Contactless on both sides of 10/1.
-- ~80 seconds per day on the replica; run one date at a time.
set @d = '2026-10-10';
select o.BUSINESS_DATE, coalesce(nullif(m.ENTRY_TYPE_ID,''),'(blank)') entry,
  count(*) methods,
  sum(coalesce(t.n_success,0) > 0) with_success,
  sum(coalesce(t.n_txn,0) > 0 and coalesce(t.n_success,0) = 0) failed_only,
  round(sum(case when coalesce(t.n_success,0) > 0 then m.AMOUNT else 0 end),0) success_amt
from default_order.ORD_ORDER o
join default_payment.PAY_PAYMENT_HEADER h on h.ORDER_ID = o.ORDER_ID and h.ORG_ID = o.ORG_ID
join default_payment.PAY_PAYMENT_METHOD m on m.PAYMENT_HEADER_PK = h.PK and m.IS_VOIDED = 0
left join (select PAYMENT_METHOD_PK, count(*) n_txn, sum(PAYMENT_RESPONSE_STATUS = 'Success') n_success
           from default_payment.PAY_PAYMENT_TRANSACTION
           where PAYMENT_METHOD_PK in (select m2.PK from default_order.ORD_ORDER o2
                 join default_payment.PAY_PAYMENT_HEADER h2 on h2.ORDER_ID = o2.ORDER_ID and h2.ORG_ID = o2.ORG_ID
                 join default_payment.PAY_PAYMENT_METHOD m2 on m2.PAYMENT_HEADER_PK = h2.PK
                 where o2.BUSINESS_DATE = @d and o2.ORG_ID in ('PS','PS-US') and o2.SELLING_LOCATION_ID < '4000')
           group by PAYMENT_METHOD_PK) t on t.PAYMENT_METHOD_PK = m.PK
where o.BUSINESS_DATE = @d and o.ORG_ID in ('PS','PS-US') and o.SELLING_LOCATION_ID < '4000' and o.IS_CANCELLED = 0
  and m.PAYMENT_TYPE in ('Credit Card','Debit','Gift Card')
group by o.BUSINESS_DATE, coalesce(nullif(m.ENTRY_TYPE_ID,''),'(blank)') order by 3 desc;
