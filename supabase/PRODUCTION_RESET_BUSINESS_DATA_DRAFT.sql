-- HIGH-RISK DRAFT ONLY — reset all operational data for one business.
-- Exact source definition extracted from Test and preserved without changing its delete order.
-- DO NOT execute without explicit approval and a separate rollback/data-retention plan.
-- This function is intentionally separate from ordinary owner RPC deployment.

begin;
set local search_path = pg_catalog, public;

do $preflight$
declare v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name) into v_missing
  from (values
    ('public.business_members'),('public.expenses'),('public.cash_transactions'),
    ('public.customer_credit_ledger'),('public.payments'),
    ('public.purchase_return_items'),('public.purchase_returns'),
    ('public.treasury_transfers'),('public.sales_return_items'),('public.sales_returns'),
    ('public.purchase_invoice_cost_snapshots'),('public.stock_adjustment_cost_snapshots'),
    ('public.stock_movements'),('public.sales_items'),('public.purchase_items'),
    ('public.sales_invoices'),('public.purchase_invoices'),('public.parties'),
    ('public.products'),('public.business_settings'),('public.audit_log')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing tables required by reset function: %',array_to_string(v_missing,', ');
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='business_members'
      and column_name='active'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema='public' and table_name='business_members'
      and column_name='role'
  ) then
    raise exception 'Missing owner membership fields';
  end if;
end
$preflight$;


CREATE OR REPLACE FUNCTION public.reset_business_data(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_counts jsonb;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول قبل تصفير بيانات النشاط'; end if;
 perform 1 from public.business_members m where m.business_id=p_business_id
   and m.user_id=auth.uid() and m.active=true and m.role='owner'
   for share;
 if not found then
  raise exception 'تصفير البيانات متاح لمالك النشاط فقط';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 perform 1 from public.businesses b where b.id=p_business_id for update;
 if not found then
  raise exception 'النشاط المطلوب غير موجود';
 end if;
 select jsonb_build_object(
  'products',(select count(*) from public.products where business_id=p_business_id),
  'parties',(select count(*) from public.parties where business_id=p_business_id),
  'purchase_invoices',(select count(*) from public.purchase_invoices where business_id=p_business_id),
  'sales_invoices',(select count(*) from public.sales_invoices where business_id=p_business_id),
  'returns',(select count(*) from public.sales_returns where business_id=p_business_id),
  'purchase_returns',(select count(*) from public.purchase_returns where business_id=p_business_id),
  'purchase_return_items',(select count(*) from public.purchase_return_items where business_id=p_business_id),
  'customer_credit_ledger',(select count(*) from public.customer_credit_ledger where business_id=p_business_id),
  'treasury_transfers',(select count(*) from public.treasury_transfers where business_id=p_business_id),
  'payments',(select count(*) from public.payments where business_id=p_business_id),
  'stock_movements',(select count(*) from public.stock_movements where business_id=p_business_id),
  'expenses',(select count(*) from public.expenses where business_id=p_business_id),
  'cash_transactions',(select count(*) from public.cash_transactions where business_id=p_business_id),
  'purchase_cost_snapshots',(select count(*) from public.purchase_invoice_cost_snapshots where business_id=p_business_id),
  'stock_cost_snapshots',(select count(*) from public.stock_adjustment_cost_snapshots where business_id=p_business_id)
 ) into v_counts;

 -- Expenses reference their original cash row with ON DELETE RESTRICT.
 -- Remove expense rows first, while preserving their linked cash rows until this point.
 delete from public.expenses where business_id=p_business_id;

 -- Cash rows may reference payments; remove cash reversals and originals before payments.
 delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;
 delete from public.cash_transactions where business_id=p_business_id;

 -- Credit-ledger reversals reference original credit events; remove them before originals.
 delete from public.customer_credit_ledger where business_id=p_business_id and reversal_of_id is not null;
 delete from public.customer_credit_ledger where business_id=p_business_id;

 -- Payment reversals reference original payments; remove reversals before originals.
 delete from public.payments where business_id=p_business_id and reversal_of_payment_id is not null;
 delete from public.payments where business_id=p_business_id;

 -- Purchase return items/headers are linked to purchase items, invoices, parties, payments and cash rows.
 delete from public.purchase_return_items where business_id=p_business_id;
 delete from public.purchase_returns where business_id=p_business_id;

 -- Transfers can have reversal rows linked to originals; cash rows were removed above.
 delete from public.treasury_transfers where business_id=p_business_id and reversal_of_transfer_id is not null;
 delete from public.treasury_transfers where business_id=p_business_id;

 delete from public.sales_return_items where business_id=p_business_id;
 delete from public.sales_returns where business_id=p_business_id;
 delete from public.purchase_invoice_cost_snapshots where business_id=p_business_id;
 delete from public.stock_adjustment_cost_snapshots where business_id=p_business_id;
 delete from public.stock_movements where business_id=p_business_id and reversal_of_movement_id is not null;
 delete from public.stock_movements where business_id=p_business_id;
 delete from public.sales_items where business_id=p_business_id;
 delete from public.purchase_items where business_id=p_business_id;
 delete from public.sales_invoices where business_id=p_business_id;
 delete from public.purchase_invoices where business_id=p_business_id;
 delete from public.parties where business_id=p_business_id;
 delete from public.products where business_id=p_business_id;
 delete from public.business_settings where business_id=p_business_id;
 delete from public.audit_log where business_id=p_business_id;

 insert into public.audit_log(business_id,actor_id,action,entity_type,details)
 values(p_business_id,auth.uid(),'business_data_reset','business',
  jsonb_build_object('deleted_counts',v_counts,'reset_at',now()));
 return jsonb_build_object('success',true,'deleted_counts',v_counts);
end;
$function$;

revoke all on function public.reset_business_data(uuid) from public, anon, authenticated;
grant execute on function public.reset_business_data(uuid) to authenticated, service_role;

commit;

-- Behavior:
-- * requires auth.uid() and active owner membership for the target business.
-- * serializes with the per-business advisory transaction lock.
-- * deletes operational records for that business in FK-safe order.
-- * preserves the business row, auth user, business membership, and operation_counters.
-- * writes a new business_data_reset audit entry containing pre-delete counts.
-- * any failure rolls back the entire function call.
-- Not executed on Test or Production.
