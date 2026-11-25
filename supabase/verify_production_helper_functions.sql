-- Read-only verifier for the final helper-function hardening stage.
do $verify$
declare v_oid oid; v_def text; v_name text;
v_helpers text[]:=array['next_operation_code(uuid,text)','assign_business_record_code()','guard_invoice_reference_business()','guard_party_opening_balance_side()','guard_product_average_cost()','lock_invoice_party_for_opening_balance()','assign_automatic_invoice_number()','apply_customer_return_average_cost()'];
v_triggers text[]:=array['cash_transactions_assign_code','expenses_assign_code','parties_assign_code','payments_assign_code','stock_movements_assign_code','treasury_transfers_assign_code','trg_auto_purchase_invoice_number','trg_auto_sales_invoice_number'];
begin
 foreach v_name in array v_helpers loop
  v_oid:=to_regprocedure('public.'||v_name);
  if v_oid is null then raise exception 'Missing helper %',v_name; end if;
  if not exists(select 1 from pg_proc p where p.oid=v_oid and coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']) then raise exception 'Empty search_path missing: %',v_name; end if;
  if has_function_privilege('anon',v_oid,'EXECUTE') or has_function_privilege('authenticated',v_oid,'EXECUTE') then raise exception 'Internal helper exposed: %',v_name; end if;
  if not has_function_privilege('service_role',v_oid,'EXECUTE') then raise exception 'service_role lacks EXECUTE: %',v_name; end if;
 end loop;
 v_oid:=to_regprocedure('public.next_operation_code(uuid,text)');
 select pg_get_functiondef(v_oid) into v_def;
 if not exists(select 1 from pg_proc p where p.oid=v_oid and p.prosecdef) or v_def not ilike '%auth.uid()%' or v_def not ilike '%business_members%' or v_def not ilike '%pg_advisory_xact_lock%' or v_def not ilike '%greatest(last_number%' or v_def not ilike '%substring(invoice_no from 7)%' or v_def ilike '%select count(*)%' then raise exception 'Counter allocation/auth/reconciliation logic failed'; end if;
 v_oid:=to_regprocedure('public.assign_automatic_invoice_number()');
 select pg_get_functiondef(v_oid) into v_def;
 if exists(select 1 from pg_proc p where p.oid=v_oid and p.prosecdef) or v_def ilike '%execute format%' or v_def ilike '%execute immediate%' then raise exception 'AUTO invoice trigger must be invoker with no dynamic SQL'; end if;
 if has_table_privilege('anon','public.operation_counters','SELECT') or has_table_privilege('authenticated','public.operation_counters','SELECT') or has_table_privilege('anon','public.operation_counters','INSERT') or has_table_privilege('authenticated','public.operation_counters','INSERT') or has_table_privilege('anon','public.operation_counters','UPDATE') or has_table_privilege('authenticated','public.operation_counters','UPDATE') then raise exception 'operation_counters unexpectedly has direct API privileges'; end if;
 foreach v_name in array v_triggers loop
  if not exists(select 1 from pg_trigger t where t.tgname=v_name and not t.tgisinternal) then raise exception 'Missing trigger %',v_name; end if;
 end loop;
 raise notice 'PASS: helper paths, counter reconciliation, invoker invoice trigger, ACLs, and 8 triggers';
end
$verify$;
