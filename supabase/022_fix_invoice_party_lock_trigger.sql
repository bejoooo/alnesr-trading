-- 022: Fix row-shape-safe branching in invoice party lock trigger.
create or replace function public.lock_invoice_party_for_opening_balance()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  party_kind text;
begin
  if tg_table_name = 'sales_invoices' then
    if new.customer_id is not null then
      select p.kind into party_kind
      from public.parties p
      where p.id = new.customer_id and p.business_id = new.business_id
      for update;
      if not found or party_kind not in ('customer','both') then
        raise exception 'Customer does not belong to this business or is not a customer';
      end if;
    end if;
  elsif tg_table_name = 'purchase_invoices' then
    if new.supplier_id is not null then
      select p.kind into party_kind
      from public.parties p
      where p.id = new.supplier_id and p.business_id = new.business_id
      for update;
      if not found or party_kind not in ('supplier','both') then
        raise exception 'Supplier does not belong to this business or is not a supplier';
      end if;
    end if;
  end if;
  return new;
end;
$function$;