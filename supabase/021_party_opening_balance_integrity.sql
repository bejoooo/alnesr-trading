-- 021: Keep party opening-balance direction consistent and serialize first invoice posting.
create or replace function public.guard_party_opening_balance_side()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.kind = 'customer' then
    new.opening_balance_side := 'receivable';
  elsif new.kind = 'supplier' then
    new.opening_balance_side := 'payable';
  elsif new.opening_balance_side not in ('receivable','payable') then
    new.opening_balance_side := 'receivable';
  end if;
  return new;
end;
$function$;

drop trigger if exists parties_opening_balance_side_guard on public.parties;
create trigger parties_opening_balance_side_guard
before insert or update of kind, opening_balance_side
on public.parties
for each row execute function public.guard_party_opening_balance_side();

create or replace function public.lock_invoice_party_for_opening_balance()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  party_kind text;
begin
  if tg_table_name = 'sales_invoices' and new.customer_id is not null then
    select p.kind into party_kind
    from public.parties p
    where p.id = new.customer_id and p.business_id = new.business_id
    for update;
    if not found or party_kind not in ('customer','both') then
      raise exception 'Customer does not belong to this business or is not a customer';
    end if;
  elsif tg_table_name = 'purchase_invoices' and new.supplier_id is not null then
    select p.kind into party_kind
    from public.parties p
    where p.id = new.supplier_id and p.business_id = new.business_id
    for update;
    if not found or party_kind not in ('supplier','both') then
      raise exception 'Supplier does not belong to this business or is not a supplier';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists sales_invoice_party_lock on public.sales_invoices;
create trigger sales_invoice_party_lock
before insert on public.sales_invoices
for each row execute function public.lock_invoice_party_for_opening_balance();

drop trigger if exists purchase_invoice_party_lock on public.purchase_invoices;
create trigger purchase_invoice_party_lock
before insert on public.purchase_invoices
for each row execute function public.lock_invoice_party_for_opening_balance();

-- Repair any legacy direction that conflicts with a single-purpose party type.
update public.parties
set opening_balance_side = case
  when kind='customer' then 'receivable'
  when kind='supplier' then 'payable'
  else opening_balance_side
end
where (kind='customer' and opening_balance_side<>'receivable')
   or (kind='supplier' and opening_balance_side<>'payable');
