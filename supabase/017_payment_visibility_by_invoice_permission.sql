-- Al Nesr Trading — restrict payment rows by invoice visibility
-- A member with payments.view must also be allowed to view the linked invoice type.
-- Sales return refunds are linked to sales invoices and therefore follow sales.view.

drop policy if exists payments_read on public.payments;

create policy payments_read
on public.payments
for select
to authenticated
using (
  public.has_business_permission(business_id, 'payments.view')
  and (
    exists (
      select 1
      from public.sales_invoices si
      where si.id = payments.invoice_id
        and si.business_id = payments.business_id
        and public.has_business_permission(payments.business_id, 'sales.view')
    )
    or exists (
      select 1
      from public.purchase_invoices pi
      where pi.id = payments.invoice_id
        and pi.business_id = payments.business_id
        and public.has_business_permission(payments.business_id, 'purchases.view')
    )
    or (
      payments.invoice_id is null
      and public.has_business_role(payments.business_id, array['owner','admin'])
    )
  )
);

do $$
declare
  policy_qual text;
begin
  select qual into policy_qual
  from pg_policies
  where schemaname='public'
    and tablename='payments'
    and policyname='payments_read'
    and cmd='SELECT';

  if policy_qual is null
     or position('sales_invoices' in policy_qual)=0
     or position('purchase_invoices' in policy_qual)=0
     or position('payments.view' in policy_qual)=0 then
    raise exception 'Payment visibility policy is missing or malformed';
  end if;
end;
$$;
