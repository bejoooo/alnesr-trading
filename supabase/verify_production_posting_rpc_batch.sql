-- Read-only verifier for invoice, returns, stock, and credit RPCs.
-- Run on Test now and on Production after the approved posting RPC stage.
-- Catalog reads only; no financial RPCs are called.

do $verify$
declare
  v_count integer;
  v_signature text;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.oid::regprocedure::text = any(array[
      'pay_customer_credit(uuid,uuid,numeric,date,text,text,text)',
      'post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)',
      'post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
      'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
      'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)',
      'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)',
      'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)',
      'post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)',
      'post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)',
      'receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)'
    ]);

  if v_count<>10 then
    raise exception 'Expected 10 posting RPC signatures, found %',v_count;
  end if;

  foreach v_signature in array array[
      'pay_customer_credit(uuid,uuid,numeric,date,text,text,text)',
      'post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)',
      'post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
      'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
      'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)',
      'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)',
      'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)',
      'post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)',
      'post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)',
      'receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)'
  ] loop
    if not has_function_privilege('authenticated',format('public.%s',v_signature),'EXECUTE')
       or not has_function_privilege('service_role',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'authenticated/service_role is missing EXECUTE on %',v_signature;
    end if;

    if has_function_privilege('anon',format('public.%s',v_signature),'EXECUTE') then
      raise exception 'anon unexpectedly has EXECUTE on %',v_signature;
    end if;

    if exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where n.nspname='public'
        and p.oid::regprocedure::text=v_signature
        and a.grantee=0 and a.privilege_type='EXECUTE'
    ) then
      raise exception 'PUBLIC unexpectedly has EXECUTE on %',v_signature;
    end if;

    if not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public'
        and p.oid::regprocedure::text=v_signature
        and p.prosecdef
        and coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']
    ) then
      raise exception 'SECURITY DEFINER/empty search_path contract failed for %',v_signature;
    end if;
  end loop;

  raise notice 'PASS: 10 posting RPC signatures including compatibility overloads, SECURITY DEFINER, empty search_path, and restricted ACLs';
end
$verify$;
