-- Al Nesr Trading — harden internal SECURITY DEFINER RPC grants and correct daily payment classification
-- Apply to the TEST Supabase project only after reviewing this migration.

-- Trigger/event-trigger functions are not public RPC endpoints.
revoke all on function public.add_business_creator_as_owner() from public, anon, authenticated;
revoke all on function public.guard_invoice_reference_business() from public, anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

-- Authorization helpers are needed by authenticated RLS policies, never by anon.
revoke all on function public.has_business_permission(uuid,text) from public, anon;
revoke all on function public.has_business_role(uuid,text[]) from public, anon;
revoke all on function public.is_business_member(uuid) from public, anon;
grant execute on function public.has_business_permission(uuid,text) to authenticated;
grant execute on function public.has_business_role(uuid,text[]) to authenticated;
grant execute on function public.is_business_member(uuid) to authenticated;

-- Backup restore is owner-only and checks auth.uid() internally; expose only to signed-in users.
revoke all on function public.restore_business_backup(uuid,jsonb) from public, anon;
grant execute on function public.restore_business_backup(uuid,jsonb) to authenticated;

-- Do not classify customer cash refunds (direction='out' linked to a sales invoice)
-- as supplier payments in the daily summary.
create or replace view public.daily_business_summary
with (security_invoker=true) as
with report_dates as (
  select business_id,invoice_date as report_date from public.sales_invoices
  union
  select business_id,invoice_date from public.purchase_invoices
  union
  select business_id,expense_date from public.expenses
  union
  select business_id,transaction_date from public.cash_transactions
  union
  select business_id,payment_date from public.payments
)
select d.business_id,d.report_date,
       coalesce(s.sales_total,0)::numeric(14,2) as sales_total,
       coalesce(pay.sales_collected,0)::numeric(14,2) as sales_collected,
       coalesce(s.sales_due,0)::numeric(14,2) as sales_outstanding,
       coalesce(p.purchase_total,0)::numeric(14,2) as purchases_total,
       coalesce(pay.purchases_paid,0)::numeric(14,2) as purchases_paid,
       coalesce(e.expenses_total,0)::numeric(14,2) as expenses_total,
       coalesce(c.cash_in,0)::numeric(14,2) as cash_in,
       coalesce(c.cash_out,0)::numeric(14,2) as cash_out
from report_dates d
left join lateral (
  select sum(total) sales_total,sum(due_total) sales_due
  from public.sales_invoices x
  where x.business_id=d.business_id and x.invoice_date=d.report_date and x.status<>'void'
) s on true
left join lateral (
  select sum(total) purchase_total
  from public.purchase_invoices x
  where x.business_id=d.business_id and x.invoice_date=d.report_date and x.status<>'void'
) p on true
left join lateral (
  select sum(amount) expenses_total from public.expenses x
  where x.business_id=d.business_id and x.expense_date=d.report_date
) e on true
left join lateral (
  select
    sum(case when x.direction='in' and exists (
      select 1 from public.sales_invoices si
      where si.id=x.invoice_id and si.business_id=x.business_id
    ) then x.amount else 0 end) as sales_collected,
    sum(case when x.direction='out' and exists (
      select 1 from public.purchase_invoices pi
      where pi.id=x.invoice_id and pi.business_id=x.business_id
    ) then x.amount else 0 end) as purchases_paid
  from public.payments x
  where x.business_id=d.business_id and x.payment_date=d.report_date
) pay on true
left join lateral (
  select sum(case when direction='in' then amount else 0 end) cash_in,
         sum(case when direction='out' then amount else 0 end) cash_out
  from public.cash_transactions x
  where x.business_id=d.business_id and x.transaction_date=d.report_date
) c on true;
