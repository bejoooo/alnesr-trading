-- Read-only structural verifier for the current Preview application schema.
-- Safe to run on Test or, after an approved migration, Production.
-- This script performs catalog checks only: no INSERT/UPDATE/DELETE/DDL.

do $verify$
declare
  item text;
  missing text[] := array[]::text[];
  rpc_name text;
  rpc_oid regprocedure;
  required_rpcs text[] := array[
    'add_business_member_by_email(uuid,text,text)',
    'create_treasury_transfer(uuid,text,text,numeric,date,text)',
    'get_treasury_balances(uuid)',
    'list_business_members(uuid)',
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
    'owner_void_purchase_return(uuid,uuid)',
    'pay_customer_credit(uuid,uuid,numeric,date,text,text,text)',
    'post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)',
    'post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
    'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)',
    'post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)',
    'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)',
    'post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)',
    'post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)',
    'post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)',
    'receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)',
    'record_cash_opening_balance(uuid,numeric,date,text)',
    'record_expense(uuid,text,numeric,date,text,text)',
    'record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)',
    'record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)',
    'record_treasury_deposit(uuid,text,numeric,text,date,text)',
    'record_treasury_withdrawal(uuid,text,numeric,text,date,text)',
    'reset_business_data(uuid)',
    'restore_business_backup(uuid,jsonb)',
    'reverse_treasury_transfer(uuid,uuid)',
    'set_party_opening_balance(uuid,uuid,numeric,text)',
    'update_business_member(uuid,uuid,text,boolean,jsonb)'
  ];
  required_tables text[] := array['business_members','businesses','cash_transactions','customer_credit_ledger','expenses','parties','payments','products','purchase_invoices','purchase_items','purchase_return_items','purchase_returns','sales_invoices','sales_items','sales_return_items','sales_returns','stock_movements','treasury_transfers'];
  required_views text[] := array['cash_balances','customer_credit_balances','customer_credit_return_balances','party_account_balances','party_account_statement','product_stock_balances'];
  required_triggers text[] := array['business_members_guard','businesses_add_creator','cash_invoice_business_guard','cash_transactions_assign_code','expenses_assign_code','parties_assign_code','parties_opening_balance_side_guard','payments_assign_code','payments_invoice_business_guard','products_guard_average_cost','purchase_invoice_party_lock','trg_auto_purchase_invoice_number','sales_invoice_party_lock','trg_auto_sales_invoice_number','stock_movements_assign_code','stock_movements_customer_return_average_cost','treasury_transfers_assign_code'];
  required_policies text[] := array['customer_credit_ledger_read','owner_read_purchase_cost_snapshots','purchase_return_items_read','purchase_returns_read','owner_read_stock_adjustment_cost_snapshots','treasury_transfers_read'];
  required_columns text[] := array['businesses.tagline','parties.is_active','parties.party_code','purchase_invoices.supplier_credit_applied_total','sales_invoices.customer_credit_applied_total','payments.sales_return_id','payments.reversal_of_payment_id','payments.posted_at','payments.party_account_type','payments.payment_code','payments.purchase_return_id','stock_movements.reversal_of_movement_id','stock_movements.posted_at','stock_movements.movement_code','stock_movements.stock_bucket','stock_movements.average_cost_before','sales_returns.status','sales_returns.posted_at','sales_returns.invoice_due_reduced_total','sales_return_items.unit_price','expenses.cash_transaction_id','expenses.status','expenses.voided_at','expenses.voided_by','expenses.expense_code','cash_transactions.reversal_of_transaction_id','cash_transactions.sales_return_id','cash_transactions.payment_id','cash_transactions.treasury_transfer_id','cash_transactions.transaction_code','cash_transactions.account_method','cash_transactions.purchase_return_id'];
begin
  foreach item in array required_tables loop
    if to_regclass(format('public.%I',item)) is null then
      missing := array_append(missing,'table public.'||item);
    end if;
  end loop;
  foreach item in array required_views loop
    if to_regclass(format('public.%I',item)) is null then
      missing := array_append(missing,'view public.'||item);
    end if;
  end loop;
  if exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='v'
      and c.relname=any(required_views)
      and not ('security_invoker=true'=any(coalesce(c.reloptions,array[]::text[])))
  ) then
    missing := array_append(missing,'all Preview views must use security_invoker=true');
  end if;
  foreach item in array required_columns loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema='public'
        and table_name=split_part(item,'.',1)
        and column_name=split_part(item,'.',2)
    ) then
      missing := array_append(missing,'column public.'||item);
    end if;
  end loop;
  foreach item in array required_triggers loop
    if not exists (
      select 1 from pg_trigger t
      join pg_class c on c.oid=t.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and t.tgname=item and not t.tgisinternal
    ) then
      missing := array_append(missing,'trigger '||item);
    end if;
  end loop;
  foreach item in array required_policies loop
    if not exists (
      select 1 from pg_policies
      where schemaname='public' and policyname=item
    ) then
      missing := array_append(missing,'policy '||item);
    end if;
  end loop;
  foreach item in array required_tables loop
    if exists (
      select 1 from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname=item and c.relkind='r'
        and not c.relrowsecurity
    ) then
      missing := array_append(missing,'RLS disabled on public.'||item);
    end if;
  end loop;
  foreach rpc_name in array required_rpcs loop
    rpc_oid := to_regprocedure(rpc_name);
    if rpc_oid is null then
      missing := array_append(missing,'RPC '||rpc_name);
    else
      if not exists (
        select 1 from pg_proc p
        where p.oid=rpc_oid and p.prosecdef
          and 'search_path=""'=any(coalesce(p.proconfig,array[]::text[]))
      ) then
        missing := array_append(missing,'RPC must be SECURITY DEFINER with empty search_path: '||rpc_name);
      end if;
      if not has_function_privilege('authenticated',rpc_oid,'EXECUTE') then
        missing := array_append(missing,'authenticated EXECUTE missing: '||rpc_name);
      end if;
      if has_function_privilege('anon',rpc_oid,'EXECUTE') then
        missing := array_append(missing,'anon EXECUTE unexpectedly granted: '||rpc_name);
      end if;
      if exists (
        select 1 from pg_proc p,
        lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where p.oid=rpc_oid and a.grantee=0 and a.privilege_type='EXECUTE'
      ) then
        missing := array_append(missing,'PUBLIC EXECUTE unexpectedly granted: '||rpc_name);
      end if;
    end if;
  end loop;
  if not exists (
    select 1 from storage.buckets
    where id='product-images' and public=false
      and file_size_limit=5242880
      and allowed_mime_types @> array['image/jpeg','image/png','image/webp']
  ) then
    missing := array_append(missing,'private product-images bucket configuration');
  end if;
  if (
    select count(*) from pg_policies
    where schemaname='storage' and tablename='objects'
      and policyname = any(array['product_images_read','product_images_insert','product_images_update','product_images_delete'])
  ) <> 4 then
    missing := array_append(missing,'four product-images Storage policies');
  end if;
  if has_table_privilege('anon','public.operation_counters','SELECT')
     or has_table_privilege('authenticated','public.operation_counters','SELECT')
     or has_table_privilege('anon','public.operation_counters','INSERT')
     or has_table_privilege('authenticated','public.operation_counters','INSERT')
     or has_table_privilege('anon','public.operation_counters','UPDATE')
     or has_table_privilege('authenticated','public.operation_counters','UPDATE')
     or has_table_privilege('anon','public.operation_counters','DELETE')
     or has_table_privilege('authenticated','public.operation_counters','DELETE') then
    missing := array_append(missing,'operation_counters must remain inaccessible directly to API roles');
  end if;
  if cardinality(missing)>0 then
    raise exception 'Preview schema verification failed (%): %',cardinality(missing),array_to_string(missing,'; ');
  end if;
end;
$verify$;

select
  'Preview schema verification passed' as verification_result,
  18 as direct_tables,
  6 as direct_views,
  39 as rpc_signatures,
  17 as triggers,
  6 as dedicated_rls_policies,
  32 as required_new_columns;
