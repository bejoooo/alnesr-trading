-- Read-only verifier for production helper functions and missing triggers.
-- Run on Test now and on Production after the approved helper/trigger stage.
-- Catalog reads only; no DDL/DML or business operations.

do $verify$
declare
  v_function_count integer;
  v_trigger_count integer;
  v_bad text[];
  v_signature text;
begin
  select count(*) into v_function_count
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid::regprocedure::text = any(array[
      'next_operation_code(uuid,text)',
      'assign_business_record_code()',
      'guard_invoice_reference_business()',
      'guard_party_opening_balance_side()',
      'guard_product_average_cost()',
      'lock_invoice_party_for_opening_balance()',
      'assign_automatic_invoice_number()',
      'apply_customer_return_average_cost()'
    ]);

  if v_function_count<>8 then
    raise exception 'Expected 8 helper functions, found %',v_function_count;
  end if;

  select array_agg(p.oid::regprocedure::text order by p.oid::regprocedure::text)
    into v_bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid::regprocedure::text = any(array[
      'next_operation_code(uuid,text)',
      'assign_business_record_code()',
      'guard_invoice_reference_business()',
      'guard_party_opening_balance_side()',
      'guard_product_average_cost()',
      'lock_invoice_party_for_opening_balance()',
      'assign_automatic_invoice_number()',
      'apply_customer_return_average_cost()'
    ])
    and not (coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']);

  if v_bad is not null then
    raise exception 'Helper functions without an empty pinned search_path: %',array_to_string(v_bad,', ');
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.oid::regprocedure::text = any(array[
        'next_operation_code(uuid,text)',
        'assign_business_record_code()',
        'guard_invoice_reference_business()'
      ])
      and not p.prosecdef
  ) then
    raise exception 'Expected SECURITY DEFINER on the three privileged helper functions';
  end if;

  if exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.oid::regprocedure::text = any(array[
        'guard_party_opening_balance_side()',
        'guard_product_average_cost()',
        'lock_invoice_party_for_opening_balance()',
        'assign_automatic_invoice_number()',
        'apply_customer_return_average_cost()'
      ])
      and p.prosecdef
  ) then
    raise exception 'Unexpected SECURITY DEFINER on a non-privileged trigger helper';
  end if;

  foreach v_signature in array array[
    'next_operation_code(uuid,text)',
    'assign_business_record_code()',
    'guard_invoice_reference_business()',
    'guard_party_opening_balance_side()',
    'guard_product_average_cost()',
    'lock_invoice_party_for_opening_balance()',
    'assign_automatic_invoice_number()',
    'apply_customer_return_average_cost()'
  ] loop
    if has_function_privilege('anon',format('public.%s',v_signature),'EXECUTE')
       or has_function_privilege('authenticated',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'anon/authenticated unexpectedly has EXECUTE on %',v_signature;
    end if;

    if not has_function_privilege('service_role',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'service_role is missing EXECUTE on %',v_signature;
    end if;

    if exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where n.nspname='public'
        and p.oid::regprocedure::text=v_signature
        and a.grantee=0
        and a.privilege_type='EXECUTE'
    ) then
      raise exception 'PUBLIC unexpectedly has EXECUTE on %',v_signature;
    end if;
  end loop;

  select count(*) into v_trigger_count
  from pg_trigger t
  where not t.tgisinternal
    and (
      (t.tgrelid='public.cash_transactions'::regclass and t.tgname='cash_transactions_assign_code')
      or (t.tgrelid='public.expenses'::regclass and t.tgname='expenses_assign_code')
      or (t.tgrelid='public.parties'::regclass and t.tgname='parties_assign_code')
      or (t.tgrelid='public.payments'::regclass and t.tgname='payments_assign_code')
      or (t.tgrelid='public.stock_movements'::regclass and t.tgname='stock_movements_assign_code')
      or (t.tgrelid='public.treasury_transfers'::regclass and t.tgname='treasury_transfers_assign_code')
      or (t.tgrelid='public.purchase_invoices'::regclass and t.tgname='trg_auto_purchase_invoice_number')
      or (t.tgrelid='public.sales_invoices'::regclass and t.tgname='trg_auto_sales_invoice_number')
    );

  if v_trigger_count<>8 then
    raise exception 'Expected 8 code/number triggers, found %',v_trigger_count;
  end if;

  raise notice 'PASS: 8 helper functions, pinned empty search_path, expected SECURITY DEFINER flags, restricted ACLs, and 8 triggers';
end
$verify$;
