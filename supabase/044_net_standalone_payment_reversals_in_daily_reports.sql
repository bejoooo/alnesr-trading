create or replace view public.daily_business_summary
with (security_invoker = true) as
with report_dates as (
  select business_id, invoice_date as report_date from public.sales_invoices where status <> 'void'
  union
  select business_id, invoice_date from public.purchase_invoices where status <> 'void'
  union
  select business_id, expense_date from public.expenses where status <> 'void'
  union
  select business_id, transaction_date from public.cash_transactions
  union
  select p.business_id, p.payment_date
  from public.payments p
  where
    (p.invoice_id is null
      or exists(select 1 from public.sales_invoices si where si.id=p.invoice_id and si.business_id=p.business_id and si.status<>'void')
      or exists(select 1 from public.purchase_invoices pi where pi.id=p.invoice_id and pi.business_id=p.business_id and pi.status<>'void'))
    and (p.sales_return_id is null
      or exists(select 1 from public.sales_returns sr where sr.id=p.sales_return_id and sr.business_id=p.business_id and sr.status<>'void'))
)
select
 d.business_id,
 d.report_date,
 coalesce((select sum(si.total) from public.sales_invoices si where si.business_id=d.business_id and si.invoice_date=d.report_date and si.status<>'void'),0)::numeric(14,2) as sales_total,
 coalesce((
   select sum(case when p.direction='in' then p.amount else -p.amount end)
   from public.payments p
   where p.business_id=d.business_id and p.payment_date=d.report_date and p.sales_return_id is null
     and (
       exists(select 1 from public.sales_invoices si where si.id=p.invoice_id and si.business_id=p.business_id and si.status<>'void')
       or (p.invoice_id is null and p.party_account_type='customer')
     )
 ),0)::numeric(14,2) as sales_collected,
 coalesce((select sum(si.due_total) from public.sales_invoices si where si.business_id=d.business_id and si.invoice_date=d.report_date and si.status<>'void'),0)::numeric(14,2) as sales_outstanding,
 coalesce((select sum(pi.total) from public.purchase_invoices pi where pi.business_id=d.business_id and pi.invoice_date=d.report_date and pi.status<>'void'),0)::numeric(14,2) as purchases_total,
 coalesce((
   select sum(case when p.direction='out' then p.amount else -p.amount end)
   from public.payments p
   where p.business_id=d.business_id and p.payment_date=d.report_date and p.sales_return_id is null
     and (
       exists(select 1 from public.purchase_invoices pi where pi.id=p.invoice_id and pi.business_id=p.business_id and pi.status<>'void')
       or (p.invoice_id is null and p.party_account_type='supplier')
     )
 ),0)::numeric(14,2) as purchases_paid,
 coalesce((select sum(e.amount) from public.expenses e where e.business_id=d.business_id and e.expense_date=d.report_date and e.status<>'void'),0)::numeric(14,2) as expenses_total,
 coalesce((select sum(c.amount) from public.cash_transactions c where c.business_id=d.business_id and c.transaction_date=d.report_date and c.direction='in'),0)::numeric(14,2) as cash_in,
 coalesce((select sum(c.amount) from public.cash_transactions c where c.business_id=d.business_id and c.transaction_date=d.report_date and c.direction='out'),0)::numeric(14,2) as cash_out
from report_dates d;
