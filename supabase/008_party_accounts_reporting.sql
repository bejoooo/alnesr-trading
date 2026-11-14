-- Al Nesr Trading — customer/supplier balances and account statement views
-- Apply after 007_stock_cash_reporting.sql on a TEST project first.

create or replace view public.party_account_balances
with (security_invoker=true) as
select p.business_id,p.id as party_id,p.kind,p.name,p.phone,
       p.opening_balance::numeric(14,2) as opening_balance,
       coalesce(s.sales_total,0)::numeric(14,2) as sales_total,
       coalesce(pi.purchases_total,0)::numeric(14,2) as purchases_total,
       coalesce(pay.customer_paid,0)::numeric(14,2) as customer_payments,
       coalesce(pay.supplier_paid,0)::numeric(14,2) as supplier_payments,
       coalesce(r.returns_total,0)::numeric(14,2) as returns_total,
       (case when p.kind in ('customer','both') then
          p.opening_balance+coalesce(s.sales_total,0)-coalesce(pay.customer_paid,0)-coalesce(r.returns_total,0)
        else 0 end)::numeric(14,2) as customer_net_balance,
       (case when p.kind in ('supplier','both') then
          p.opening_balance+coalesce(pi.purchases_total,0)-coalesce(pay.supplier_paid,0)
        else 0 end)::numeric(14,2) as supplier_net_balance
from public.parties p
left join lateral (
  select sum(total) as sales_total from public.sales_invoices x
  where x.business_id=p.business_id and x.customer_id=p.id and x.status<>'void'
) s on true
left join lateral (
  select sum(total) as purchases_total from public.purchase_invoices x
  where x.business_id=p.business_id and x.supplier_id=p.id and x.status<>'void'
) pi on true
left join lateral (
  select sum(case when direction='in' then amount else 0 end) as customer_paid,
         sum(case when direction='out' then amount else 0 end) as supplier_paid
  from public.payments x
  where x.business_id=p.business_id and x.party_id=p.id
) pay on true
left join lateral (
  select sum(refund_total) as returns_total from public.sales_returns x
  where x.business_id=p.business_id and x.customer_id=p.id
) r on true;

create or replace view public.party_account_statement
with (security_invoker=true) as
select p.business_id,p.id as party_id,p.name as party_name,
       'opening_balance'::text as entry_type,
       null::uuid as entry_id,null::text as reference_no,
       p.created_at::date as entry_date,
       p.opening_balance::numeric(14,2) as debit,
       0::numeric(14,2) as credit,
       'رصيد افتتاحي'::text as description
from public.parties p
where p.opening_balance<>0
union all
select i.business_id,i.customer_id,p.name,'sale_invoice',i.id,i.invoice_no,
       i.invoice_date,i.total,0,'فاتورة مبيعات'
from public.sales_invoices i
join public.parties p on p.id=i.customer_id and p.business_id=i.business_id
where i.customer_id is not null and i.status<>'void'
union all
select i.business_id,i.supplier_id,p.name,'purchase_invoice',i.id,i.invoice_no,
       i.invoice_date,0,i.total,'فاتورة مشتريات'
from public.purchase_invoices i
join public.parties p on p.id=i.supplier_id and p.business_id=i.business_id
where i.supplier_id is not null and i.status<>'void'
union all
select x.business_id,x.party_id,p.name,'payment',x.id,x.reference,
       x.payment_date,
       case when x.direction='out' then x.amount else 0 end,
       case when x.direction='in' then x.amount else 0 end,
       coalesce(x.notes,'دفعة')
from public.payments x
join public.parties p on p.id=x.party_id and p.business_id=x.business_id
where x.party_id is not null
union all
select r.business_id,r.customer_id,p.name,'sales_return',r.id,r.return_no,
       r.return_date,0,r.refund_total,'مرتجع مبيعات'
from public.sales_returns r
join public.parties p on p.id=r.customer_id and p.business_id=r.business_id
where r.customer_id is not null;

grant select on public.party_account_balances to authenticated;
grant select on public.party_account_statement to authenticated;
