-- Read-only verifier for the six production reporting views.
-- Safe to run on Test now and on Production after the approved view stage.
-- This script performs catalog reads only; it does not modify database objects or data.

do $verify$
declare
  v_count integer;
  v_view text;
  v_has_public_select boolean;
begin
  select count(*) into v_count
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relkind='v'
    and c.relname = any(array[
      'cash_balances',
      'product_stock_balances',
      'party_account_balances',
      'party_account_statement',
      'customer_credit_balances',
      'customer_credit_return_balances'
    ]);

  if v_count<>6 then
    raise exception 'Expected 6 reporting views, found %',v_count;
  end if;

  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public'
      and c.relname = any(array[
        'cash_balances',
        'product_stock_balances',
        'party_account_balances',
        'party_account_statement',
        'customer_credit_balances',
        'customer_credit_return_balances'
      ])
      and not (coalesce(c.reloptions,'{}'::text[]) @> array['security_invoker=true'])
  ) then
    raise exception 'One or more reporting views do not have security_invoker=true';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='cash_balances'
  ) is distinct from array['business_id','balance']::text[] then
    raise exception 'cash_balances column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='cash_balances'
  ) is distinct from array['uuid','numeric']::text[] then
    raise exception 'cash_balances type contract mismatch';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='product_stock_balances'
  ) is distinct from array[
    'business_id','product_id','code','name','unit','minimum_stock',
    'quantity_on_hand','average_cost','stock_value','below_minimum',
    'has_stock_history','out_of_stock','damaged_quantity','total_stock_quantity'
  ]::text[] then
    raise exception 'product_stock_balances column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='product_stock_balances'
  ) is distinct from array[
    'uuid','uuid','text','text','text','numeric','numeric','numeric',
    'numeric','bool','bool','bool','numeric','numeric'
  ]::text[] then
    raise exception 'product_stock_balances type contract mismatch';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='party_account_balances'
  ) is distinct from array[
    'business_id','party_id','kind','name','phone','opening_balance',
    'sales_total','purchases_total','customer_payments','supplier_payments',
    'returns_total','customer_net_balance','supplier_net_balance',
    'opening_balance_side','customer_net_collected','purchase_returns_total'
  ]::text[] then
    raise exception 'party_account_balances column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='party_account_balances'
  ) is distinct from array[
    'uuid','uuid','text','text','text','numeric','numeric','numeric',
    'numeric','numeric','numeric','numeric','numeric','text','numeric','numeric'
  ]::text[] then
    raise exception 'party_account_balances type contract mismatch';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='party_account_statement'
  ) is distinct from array[
    'business_id','party_id','party_name','entry_type','entry_id',
    'reference_no','entry_date','debit','credit','description','entry_timestamp'
  ]::text[] then
    raise exception 'party_account_statement column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='party_account_statement'
  ) is distinct from array[
    'uuid','uuid','text','text','uuid','text','date','numeric','numeric','text','timestamptz'
  ]::text[] then
    raise exception 'party_account_statement type contract mismatch';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='customer_credit_balances'
  ) is distinct from array['business_id','party_id','available_credit']::text[] then
    raise exception 'customer_credit_balances column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='customer_credit_balances'
  ) is distinct from array['uuid','uuid','numeric']::text[] then
    raise exception 'customer_credit_balances type contract mismatch';
  end if;

  if (
    select array_agg(column_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='customer_credit_return_balances'
  ) is distinct from array[
    'business_id','party_id','source_return_id','available_credit','credit_created'
  ]::text[] then
    raise exception 'customer_credit_return_balances column contract mismatch';
  end if;

  if (
    select array_agg(udt_name order by ordinal_position)
    from information_schema.columns
    where table_schema='public' and table_name='customer_credit_return_balances'
  ) is distinct from array['uuid','uuid','uuid','numeric','numeric']::text[] then
    raise exception 'customer_credit_return_balances type contract mismatch';
  end if;

  foreach v_view in array array[
    'customer_credit_balances',
    'customer_credit_return_balances'
  ] loop
    if has_table_privilege('anon',format('public.%I',v_view),'SELECT') then
      raise exception 'anon unexpectedly has SELECT on %',v_view;
    end if;

    if not has_table_privilege('authenticated',format('public.%I',v_view),'SELECT') then
      raise exception 'authenticated is missing SELECT on %',v_view;
    end if;

    if not has_table_privilege('service_role',format('public.%I',v_view),'SELECT') then
      raise exception 'service_role is missing SELECT on %',v_view;
    end if;

    select exists (
      select 1
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) a
      where n.nspname='public'
        and c.relname=v_view
        and a.grantee=0
        and a.privilege_type='SELECT'
    ) into v_has_public_select;

    if v_has_public_select then
      raise exception 'PUBLIC unexpectedly has SELECT on %',v_view;
    end if;
  end loop;

  raise notice 'PASS: all six reporting views match column/type contracts, use security_invoker, and the two customer-credit views have restricted SELECT ACLs';
end
$verify$;
