-- Al Nesr Trading — post-migration structural verification
-- Run after applying schema.sql and migrations 002 through 011 in order.
-- This checks that required objects exist; it does NOT replace live transaction tests.

do $$
declare
  required_table text;
  required_view text;
  required_function text;
  required_policy text;
begin
  foreach required_table in array array[
    'businesses','business_members','products','parties','purchase_invoices',
    'purchase_items','sales_invoices','sales_items','payments','stock_movements',
    'sales_returns','sales_return_items','expenses','cash_transactions',
    'business_settings','audit_log'
  ] loop
    if to_regclass('public.'||required_table) is null then
      raise exception 'Missing required table: %',required_table;
    end if;
  end loop;

  foreach required_view in array array[
    'product_stock_balances','cash_balances','daily_business_summary',
    'party_account_balances','party_account_statement'
  ] loop
    if to_regclass('public.'||required_view) is null then
      raise exception 'Missing required view: %',required_view;
    end if;
  end loop;

  foreach required_function in array array[
    'public.post_purchase(uuid,text,uuid,date,jsonb,numeric,numeric,text)',
    'public.post_sale(uuid,text,uuid,date,jsonb,numeric,numeric,text)',
    'public.record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)',
    'public.record_cash_deposit(uuid,numeric,text,date,text)',
    'public.record_expense(uuid,text,numeric,date,text)',
    'public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)',
    'public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)',
    'public.record_cash_opening_balance(uuid,numeric,date,text)',
    'public.record_cash_withdrawal(uuid,numeric,text,date,text)',
    'public.set_party_opening_balance(uuid,uuid,numeric,text)',
    'public.restore_business_backup(uuid,jsonb)'
  ] loop
    if to_regprocedure(required_function) is null then
      raise exception 'Missing required function: %',required_function;
    end if;
  end loop;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='products' and c.relrowsecurity
  ) then
    raise exception 'Row level security is not enabled on products';
  end if;

  if not exists (select 1 from storage.buckets where id='product-images' and public=false) then
    raise exception 'Private product-images storage bucket is missing';
  end if;

  foreach required_policy in array array[
    'product_images_read','product_images_insert','product_images_update','product_images_delete'
  ] loop
    if not exists (
      select 1 from pg_policies
      where schemaname='storage' and tablename='objects' and policyname=required_policy
    ) then
      raise exception 'Missing storage policy: %',required_policy;
    end if;
  end loop;

  if not exists (
    select 1 from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname='sales_invoices' and c.relrowsecurity
  ) then
    raise exception 'Row level security is not enabled on sales_invoices';
  end if;

  if not exists (
    select 1 from pg_trigger
    where tgrelid='public.products'::regclass
      and tgname='products_guard_average_cost' and not tgisinternal
  ) then
    raise exception 'Product average-cost protection trigger is missing';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename = any(array[
        'purchase_invoices','purchase_items','sales_invoices','sales_items',
        'payments','stock_movements','sales_returns','sales_return_items',
        'expenses','cash_transactions'
      ])
      and cmd <> 'SELECT'
  ) then
    raise exception 'Transactional tables still expose direct write policies';
  end if;
end;
$$;

select 'Al Nesr Trading schema verification passed' as verification_result;
