-- Al Nesr Trading — same-business invoice reference guards
-- Apply after 005_sales_returns.sql.

create or replace function public.guard_invoice_reference_business()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.invoice_id is not null then
    if not exists (
      select 1 from public.sales_invoices s
      where s.id=new.invoice_id and s.business_id=new.business_id
    ) and not exists (
      select 1 from public.purchase_invoices p
      where p.id=new.invoice_id and p.business_id=new.business_id
    ) then
      raise exception 'Invoice reference must belong to the same business';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists payments_invoice_business_guard on public.payments;
create trigger payments_invoice_business_guard
before insert or update of business_id,invoice_id on public.payments
for each row execute function public.guard_invoice_reference_business();

drop trigger if exists cash_invoice_business_guard on public.cash_transactions;
create trigger cash_invoice_business_guard
before insert or update of business_id,invoice_id on public.cash_transactions
for each row execute function public.guard_invoice_reference_business();
