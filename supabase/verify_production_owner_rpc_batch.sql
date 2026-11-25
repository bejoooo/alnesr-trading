-- Read-only verifier for owner management/archive/reversal RPC batch.
-- Run on Test now and on Production after the approved owner RPC stage.
-- Does not invoke any owner action or change data.

do $verify$
declare
  v_count integer;
  v_signature text;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid::regprocedure::text = any(array[
      'add_business_member_by_email(uuid,text,text)',
      'list_business_members(uuid)',
      'update_business_member(uuid,uuid,text,boolean,jsonb)',
      'owner_remove_cash_opening_balance(uuid)',
      'owner_remove_cash_transaction(uuid,uuid)',
      'owner_remove_expense(uuid,uuid)',
      'owner_remove_party(uuid,uuid)',
      'owner_remove_party_opening_balance(uuid,uuid)',
      'owner_remove_product(uuid,uuid)',
      'owner_remove_sales_return(uuid,uuid)',
      'owner_restore_party(uuid,uuid)',
      'owner_restore_product(uuid,uuid)',
      'owner_reverse_customer_invoice_payment(uuid,uuid)',
      'owner_reverse_invoice_payment(uuid,uuid)',
      'owner_reverse_standalone_party_payment(uuid,uuid)',
      'owner_void_invoice(uuid,text,uuid)',
      'owner_void_purchase_return(uuid,uuid)'
    ]);

  if v_count<>17 then
    raise exception 'Expected 17 owner RPC signatures, found %',v_count;
  end if;

  foreach v_signature in array array[
      'add_business_member_by_email(uuid,text,text)',
      'list_business_members(uuid)',
      'update_business_member(uuid,uuid,text,boolean,jsonb)',
      'owner_remove_cash_opening_balance(uuid)',
      'owner_remove_cash_transaction(uuid,uuid)',
      'owner_remove_expense(uuid,uuid)',
      'owner_remove_party(uuid,uuid)',
      'owner_remove_party_opening_balance(uuid,uuid)',
      'owner_remove_product(uuid,uuid)',
      'owner_remove_sales_return(uuid,uuid)',
      'owner_restore_party(uuid,uuid)',
      'owner_restore_product(uuid,uuid)',
      'owner_reverse_customer_invoice_payment(uuid,uuid)',
      'owner_reverse_invoice_payment(uuid,uuid)',
      'owner_reverse_standalone_party_payment(uuid,uuid)',
      'owner_void_invoice(uuid,text,uuid)',
      'owner_void_purchase_return(uuid,uuid)'
  ] loop
    if not has_function_privilege('authenticated',format('public.%s',v_signature),'EXECUTE')
       or not has_function_privilege('service_role',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'authenticated/service_role missing EXECUTE on %',v_signature;
    end if;

    if has_function_privilege('anon',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'anon unexpectedly has EXECUTE on %',v_signature;
    end if;

    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where n.nspname='public' and p.oid::regprocedure::text=v_signature
        and a.grantee=0 and a.privilege_type='EXECUTE'
    ) then
      raise exception 'PUBLIC unexpectedly has EXECUTE on %',v_signature;
    end if;

    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.oid::regprocedure::text=v_signature
        and p.prosecdef
        and coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']
    ) then
      raise exception 'SECURITY DEFINER/empty search_path failed for %',v_signature;
    end if;

    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.oid::regprocedure::text=v_signature
        and pg_get_functiondef(p.oid) ilike '%auth.uid()%'
        and pg_get_functiondef(p.oid) ilike '%business_members%'
    ) then
      raise exception 'Missing user identity or active membership check in %',v_signature;
    end if;
  end loop;

  raise notice 'PASS: 17 owner RPCs, SECURITY DEFINER, empty search_path, membership checks, and restricted ACLs';
end
$verify$;
