-- DRAFT ONLY — production helper functions and missing trigger stage
-- Prerequisites (must be applied in order, not by this file):
--   1) PRODUCTION_NEW_TABLES_DRAFT.sql
--   2) PRODUCTION_MISSING_COLUMNS_DRAFT.sql
--   3) PRODUCTION_STRUCTURAL_FK_DRAFT.sql
-- This file is an additive draft. It has NOT been executed on Test or Production.
-- It does not recreate financial RPCs, views, or existing triggers.

begin;

-- Fail closed if this stage is attempted before its prerequisite schema exists.
do $preflight$
declare
  v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name)
    into v_missing
  from (values
    ('public.operation_counters'),
    ('public.purchase_returns'),
    ('public.treasury_transfers')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing prerequisite tables: %', array_to_string(v_missing, ', ');
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='stock_movements'
      and column_name='average_cost_before'
  ) then
    raise exception 'Missing prerequisite column public.stock_movements.average_cost_before';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='treasury_transfers'
      and column_name='transfer_code'
  ) then
    raise exception 'Missing prerequisite column public.treasury_transfers.transfer_code';
  end if;
end
$preflight$;

-- Atomic per-business/per-operation counter. If a counter row is absent,
-- initialize from the greater of row count and the highest existing code suffix.
-- This avoids reusing a sequence number after historical deletions/gaps.
create or replace function public.next_operation_code(
  p_business_id uuid,
  p_operation_type text
)
returns text
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_number bigint;
  v_existing bigint;
  v_max_code bigint;
begin
  if auth.uid() is null or not exists (
    select 1
    from public.business_members
    where business_id=p_business_id
      and user_id=auth.uid()
      and active
  ) then
    raise exception 'Not authorized';
  end if;

  if p_operation_type not in (
    'purchase_invoice','sales_invoice','sales_return','purchase_return',
    'party','payment','cash_transaction','expense','treasury_transfer',
    'stock_movement'
  ) then
    raise exception 'Unsupported operation type';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(p_business_id::text || ':' || p_operation_type, 0)
  );

  select last_number
    into v_number
  from public.operation_counters
  where business_id=p_business_id
    and operation_type=p_operation_type
  for update;

  if not found then
    v_existing := case p_operation_type
      when 'purchase_invoice' then (
        select count(*) from public.purchase_invoices where business_id=p_business_id
      )
      when 'sales_invoice' then (
        select count(*) from public.sales_invoices where business_id=p_business_id
      )
      when 'sales_return' then (
        select count(*) from public.sales_returns where business_id=p_business_id
      )
      when 'purchase_return' then (
        select count(*) from public.purchase_returns where business_id=p_business_id
      )
      when 'party' then (
        select count(*) from public.parties where business_id=p_business_id
      )
      when 'payment' then (
        select count(*) from public.payments where business_id=p_business_id
      )
      when 'cash_transaction' then (
        select count(*) from public.cash_transactions where business_id=p_business_id
      )
      when 'expense' then (
        select count(*) from public.expenses where business_id=p_business_id
      )
      when 'treasury_transfer' then (
        select count(*) from public.treasury_transfers where business_id=p_business_id
      )
      when 'stock_movement' then (
        select count(*) from public.stock_movements where business_id=p_business_id
      )
    end;

    v_max_code := case p_operation_type
      when 'purchase_invoice' then (
        select max(substring(invoice_no from 7)::bigint)
        from public.purchase_invoices
        where business_id=p_business_id and invoice_no ~ '^[0-9]{6}[0-9]+$'
      )
      when 'sales_invoice' then (
        select max(substring(invoice_no from 7)::bigint)
        from public.sales_invoices
        where business_id=p_business_id and invoice_no ~ '^[0-9]{6}[0-9]+$'
      )
      when 'sales_return' then (
        select max(substring(return_no from 7)::bigint)
        from public.sales_returns
        where business_id=p_business_id and return_no ~ '^[0-9]{6}[0-9]+$'
      )
      when 'purchase_return' then (
        select max(substring(return_no from 7)::bigint)
        from public.purchase_returns
        where business_id=p_business_id and return_no ~ '^[0-9]{6}[0-9]+$'
      )
      when 'party' then (
        select max(substring(party_code from 7)::bigint)
        from public.parties
        where business_id=p_business_id and party_code ~ '^[0-9]{6}[0-9]+$'
      )
      when 'payment' then (
        select max(substring(payment_code from 7)::bigint)
        from public.payments
        where business_id=p_business_id and payment_code ~ '^[0-9]{6}[0-9]+$'
      )
      when 'cash_transaction' then (
        select max(substring(transaction_code from 7)::bigint)
        from public.cash_transactions
        where business_id=p_business_id and transaction_code ~ '^[0-9]{6}[0-9]+$'
      )
      when 'expense' then (
        select max(substring(expense_code from 7)::bigint)
        from public.expenses
        where business_id=p_business_id and expense_code ~ '^[0-9]{6}[0-9]+$'
      )
      when 'treasury_transfer' then (
        select max(substring(transfer_code from 7)::bigint)
        from public.treasury_transfers
        where business_id=p_business_id and transfer_code ~ '^[0-9]{6}[0-9]+$'
      )
      when 'stock_movement' then (
        select max(substring(movement_code from 7)::bigint)
        from public.stock_movements
        where business_id=p_business_id and movement_code ~ '^[0-9]{6}[0-9]+$'
      )
    end;

    v_existing := greatest(coalesce(v_existing,0),coalesce(v_max_code,0));

    insert into public.operation_counters(business_id,operation_type,last_number)
    values(p_business_id,p_operation_type,v_existing+1)
    returning last_number into v_number;
  else
    update public.operation_counters
    set last_number=last_number+1,
        updated_at=clock_timestamp()
    where business_id=p_business_id
      and operation_type=p_operation_type
    returning last_number into v_number;
  end if;

  return to_char(timezone('Africa/Cairo',clock_timestamp()),'DDMMYY') || v_number::text;
end
$function$;

create or replace function public.assign_business_record_code()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_current text;
begin
  v_current := to_jsonb(new)->>tg_argv[1];

  if coalesce(v_current,'')='' then
    new := jsonb_populate_record(
      new,
      jsonb_build_object(
        tg_argv[1],
        public.next_operation_code(new.business_id,tg_argv[0])
      )
    );
  end if;

  return new;
end
$function$;

-- Same-business invoice reference validation, with a pinned empty search_path.
create or replace function public.guard_invoice_reference_business()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
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
end
$function$;

create or replace function public.guard_party_opening_balance_side()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if new.kind='customer' then
    new.opening_balance_side:='receivable';
  elsif new.kind='supplier' then
    new.opening_balance_side:='payable';
  elsif new.opening_balance_side not in ('receivable','payable') then
    new.opening_balance_side:='receivable';
  end if;

  return new;
end
$function$;

create or replace function public.guard_product_average_cost()
returns trigger
language plpgsql
set search_path = ''
as $function$
begin
  if tg_op='INSERT' then
    if new.average_cost<>0 and current_user<>'postgres' then
      raise exception 'Average cost can only be set by inventory operations';
    end if;
  elsif new.average_cost is distinct from old.average_cost
      and current_user<>'postgres' then
    raise exception 'Average cost can only be changed by inventory operations';
  end if;

  return new;
end
$function$;

create or replace function public.lock_invoice_party_for_opening_balance()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  party_kind text;
begin
  if tg_table_name='sales_invoices' then
    if new.customer_id is not null then
      select p.kind into party_kind
      from public.parties p
      where p.id=new.customer_id and p.business_id=new.business_id
      for update;

      if not found or party_kind not in ('customer','both') then
        raise exception 'Customer does not belong to this business or is not a customer';
      end if;
    end if;
  elsif tg_table_name='purchase_invoices' then
    if new.supplier_id is not null then
      select p.kind into party_kind
      from public.parties p
      where p.id=new.supplier_id and p.business_id=new.business_id
      for update;

      if not found or party_kind not in ('supplier','both') then
        raise exception 'Supplier does not belong to this business or is not a supplier';
      end if;
    end if;
  end if;

  return new;
end
$function$;

-- Hardened invoice numbering trigger; only the two invoice tables are accepted.
create or replace function public.assign_automatic_invoice_number()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_kind text;
  v_next bigint;
begin
  if upper(trim(coalesce(new.invoice_no,''))) not in ('AUTO','تلقائي') then
    return new;
  end if;

  if tg_table_name not in ('sales_invoices','purchase_invoices') then
    raise exception 'Automatic invoice numbering is not supported for this table';
  end if;

  v_kind := case when tg_table_name='sales_invoices' then 'sales' else 'purchases' end;

  perform pg_advisory_xact_lock(
    hashtextextended(new.business_id::text || ':invoice:' || v_kind, 0)
  );

  execute format(
    'select coalesce(max((substring(invoice_no from ''([0-9]+)$''))::bigint),0)+1
       from public.%I
      where business_id=$1 and invoice_no ~ ''[0-9]+$''',
    tg_table_name
  )
  into v_next
  using new.business_id;

  new.invoice_no := v_next::text;
  return new;
end
$function$;

-- Keep the Test behavior that records the prior average cost for safe return reversal.
create or replace function public.apply_customer_return_average_cost()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  old_average numeric(14,4);
  total_quantity numeric(14,3);
  old_quantity numeric(14,3);
  new_average numeric(14,2);
begin
  if new.movement_type<>'customer_return_good' then
    return new;
  end if;

  if new.quantity_delta<=0 or new.unit_cost is null or new.unit_cost<0 then
    raise exception 'Invalid good customer return stock movement cost or quantity';
  end if;

  select p.average_cost into old_average
  from public.products p
  where p.id=new.product_id and p.business_id=new.business_id
  for update;

  if not found then
    raise exception 'Product for customer return movement was not found';
  end if;

  select coalesce(sum(sm.quantity_delta),0)
  into total_quantity
  from public.stock_movements sm
  where sm.business_id=new.business_id and sm.product_id=new.product_id;

  old_quantity := total_quantity-new.quantity_delta;
  if old_quantity<0 or total_quantity<=0 then
    raise exception 'Invalid stock balance while applying customer return';
  end if;

  new_average := round(
    ((old_quantity*old_average)+(new.quantity_delta*new.unit_cost))/total_quantity,
    2
  );

  update public.stock_movements
  set average_cost_before=old_average
  where id=new.id and business_id=new.business_id;

  update public.products
  set average_cost=new_average,updated_at=now()
  where id=new.product_id and business_id=new.business_id;

  return new;
end
$function$;

-- Match Test's restricted function ACLs. Trigger functions are not public RPC endpoints.
revoke all on function public.next_operation_code(uuid,text) from public, anon, authenticated;
revoke all on function public.assign_business_record_code() from public, anon, authenticated;
revoke all on function public.guard_invoice_reference_business() from public, anon, authenticated;
revoke all on function public.guard_party_opening_balance_side() from public, anon, authenticated;
revoke all on function public.guard_product_average_cost() from public, anon, authenticated;
revoke all on function public.lock_invoice_party_for_opening_balance() from public, anon, authenticated;
revoke all on function public.assign_automatic_invoice_number() from public, anon, authenticated;
revoke all on function public.apply_customer_return_average_cost() from public, anon, authenticated;

grant execute on function public.next_operation_code(uuid,text) to service_role;
grant execute on function public.assign_business_record_code() to service_role;
grant execute on function public.guard_invoice_reference_business() to service_role;
grant execute on function public.guard_party_opening_balance_side() to service_role;
grant execute on function public.guard_product_average_cost() to service_role;
grant execute on function public.lock_invoice_party_for_opening_balance() to service_role;
grant execute on function public.assign_automatic_invoice_number() to service_role;
grant execute on function public.apply_customer_return_average_cost() to service_role;

-- Create only the eight triggers absent from the inspected Production schema.
do $triggers$
begin
  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.cash_transactions'::regclass
      and tgname='cash_transactions_assign_code' and not tgisinternal
  ) then
    create trigger cash_transactions_assign_code
    before insert on public.cash_transactions
    for each row execute function public.assign_business_record_code('cash_transaction','transaction_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.expenses'::regclass
      and tgname='expenses_assign_code' and not tgisinternal
  ) then
    create trigger expenses_assign_code
    before insert on public.expenses
    for each row execute function public.assign_business_record_code('expense','expense_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.parties'::regclass
      and tgname='parties_assign_code' and not tgisinternal
  ) then
    create trigger parties_assign_code
    before insert on public.parties
    for each row execute function public.assign_business_record_code('party','party_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.payments'::regclass
      and tgname='payments_assign_code' and not tgisinternal
  ) then
    create trigger payments_assign_code
    before insert on public.payments
    for each row execute function public.assign_business_record_code('payment','payment_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.stock_movements'::regclass
      and tgname='stock_movements_assign_code' and not tgisinternal
  ) then
    create trigger stock_movements_assign_code
    before insert on public.stock_movements
    for each row execute function public.assign_business_record_code('stock_movement','movement_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.treasury_transfers'::regclass
      and tgname='treasury_transfers_assign_code' and not tgisinternal
  ) then
    create trigger treasury_transfers_assign_code
    before insert on public.treasury_transfers
    for each row execute function public.assign_business_record_code('treasury_transfer','transfer_code');
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.purchase_invoices'::regclass
      and tgname='trg_auto_purchase_invoice_number' and not tgisinternal
  ) then
    create trigger trg_auto_purchase_invoice_number
    before insert on public.purchase_invoices
    for each row execute function public.assign_automatic_invoice_number();
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.sales_invoices'::regclass
      and tgname='trg_auto_sales_invoice_number' and not tgisinternal
  ) then
    create trigger trg_auto_sales_invoice_number
    before insert on public.sales_invoices
    for each row execute function public.assign_automatic_invoice_number();
  end if;
end
$triggers$;

commit;

-- Post-stage checks to run separately after review:
-- * confirm 8 triggers exist exactly once and all 8 helper functions have search_path=''.
-- * confirm SECURITY DEFINER only on next_operation_code, assign_business_record_code,
--   and guard_invoice_reference_business; verify owner is postgres.
-- * confirm anon/PUBLIC/authenticated have no EXECUTE on internal helpers.
-- * verify counter seeds against existing DDMMYY+sequence codes before first writes.
-- * test concurrent code allocation and each trigger on an isolated disposable Test copy.
-- No data backfill, financial RPC execution, or production write is performed by this draft.
