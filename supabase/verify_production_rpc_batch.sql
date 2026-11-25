-- Read-only verifier for the first production RPC batch.
-- Run on Test now and on Production after the approved RPC batch.
-- Catalog reads only; it does not call the RPCs or change data.

do $verify$
declare
  v_count integer;
  v_signature text;
begin
  select count(*) into v_count
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid::regprocedure::text = any(array[
      'create_treasury_transfer(uuid,text,text,numeric,date,text)',
      'get_treasury_balances(uuid)',
      'record_cash_opening_balance(uuid,numeric,date,text)',
      'record_expense(uuid,text,numeric,date,text,text)',
      'record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)',
      'record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)',
      'record_treasury_deposit(uuid,text,numeric,text,date,text)',
      'record_treasury_withdrawal(uuid,text,numeric,text,date,text)',
      'reverse_treasury_transfer(uuid,uuid)',
      'set_party_opening_balance(uuid,uuid,numeric,text)'
    ]);

  if v_count<>10 then
    raise exception 'Expected 10 RPC signatures, found %',v_count;
  end if;

  foreach v_signature in array array[
    'create_treasury_transfer(uuid,text,text,numeric,date,text)',
    'get_treasury_balances(uuid)',
    'record_cash_opening_balance(uuid,numeric,date,text)',
    'record_expense(uuid,text,numeric,date,text,text)',
    'record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)',
    'record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)',
    'record_treasury_deposit(uuid,text,numeric,text,date,text)',
    'record_treasury_withdrawal(uuid,text,numeric,text,date,text)',
    'reverse_treasury_transfer(uuid,uuid)',
    'set_party_opening_balance(uuid,uuid,numeric,text)'
  ] loop
    if not has_function_privilege('authenticated',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'authenticated is missing EXECUTE on %',v_signature;
    end if;

    if not has_function_privilege('service_role',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'service_role is missing EXECUTE on %',v_signature;
    end if;

    if has_function_privilege('anon',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'anon unexpectedly has EXECUTE on %',v_signature;
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

    if not exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.oid::regprocedure::text=v_signature
        and p.prosecdef
        and coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']
    ) then
      raise exception 'SECURITY DEFINER or empty search_path contract failed for %',v_signature;
    end if;
  end loop;

  raise notice 'PASS: 10 RPC signatures, SECURITY DEFINER, empty search_path, and authenticated/service_role-only execution';
end
$verify$;
