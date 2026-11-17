
create or replace view public.party_account_balances
with (security_invoker = true)
as
select
 p.business_id,p.id as party_id,p.kind,p.name,p.phone,p.opening_balance,
 coalesce(s.sales_total,0)::numeric(14,2) as sales_total,
 coalesce(pi.purchases_total,0)::numeric(14,2) as purchases_total,
 coalesce(pay.customer_paid,0)::numeric(14,2) as customer_payments,
 coalesce(pay.supplier_paid,0)::numeric(14,2) as supplier_payments,
 coalesce(r.returns_total,0)::numeric(14,2) as returns_total,
 (case when p.kind=any(array['customer','both']::text[])
  then ((case when p.opening_balance_side='receivable' then p.opening_balance else 0 end
   +coalesce(s.sales_total,0))-coalesce(pay.customer_paid,0)-coalesce(r.returns_total,0)
   +coalesce(pay.customer_refunds,0)) else 0 end)::numeric(14,2) as customer_net_balance,
 (case when p.kind=any(array['supplier','both']::text[])
  then (case when p.opening_balance_side='payable' then p.opening_balance else 0 end
   +coalesce(pi.purchases_total,0)-coalesce(pay.supplier_paid,0))
  else 0 end)::numeric(14,2) as supplier_net_balance,
 p.opening_balance_side
from public.parties p
left join lateral (
 select sum(x.total) sales_total from public.sales_invoices x
 where x.business_id=p.business_id and x.customer_id=p.id and x.status<>'void'
) s on true
left join lateral (
 select sum(x.total) purchases_total from public.purchase_invoices x
 where x.business_id=p.business_id and x.supplier_id=p.id and x.status<>'void'
) pi on true
left join lateral (
 select
  sum(case
   when x.sales_return_id is null and exists(
    select 1 from public.sales_invoices si
    where si.id=x.invoice_id and si.business_id=x.business_id
      and si.customer_id=p.id and si.status<>'void'
   ) then case when x.direction='in' then x.amount else -x.amount end
   else 0 end) customer_paid,
  sum(case
   when exists(
    select 1 from public.purchase_invoices px
    where px.id=x.invoice_id and px.business_id=x.business_id
      and px.supplier_id=p.id and px.status<>'void'
   ) then case when x.direction='out' then x.amount else -x.amount end
   else 0 end) supplier_paid,
  sum(case
   when x.sales_return_id is not null and exists(
    select 1 from public.sales_returns sr
    where sr.id=x.sales_return_id and sr.business_id=x.business_id
      and sr.customer_id=p.id and sr.status<>'void'
   ) then case when x.direction='out' then x.amount else -x.amount end
   else 0 end) customer_refunds
 from public.payments x where x.business_id=p.business_id and x.party_id=p.id
) pay on true
left join lateral (
 select sum(x.refund_total) returns_total from public.sales_returns x
 where x.business_id=p.business_id and x.customer_id=p.id and x.status<>'void'
) r on true;
