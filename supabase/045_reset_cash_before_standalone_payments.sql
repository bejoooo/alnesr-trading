create or replace function public.reset_business_data(p_business_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_counts jsonb;
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول قبل تصفير بيانات النشاط'; end if;
 if not exists(select 1 from public.business_members m where m.business_id=p_business_id
   and m.user_id=auth.uid() and m.active=true and m.role='owner') then
  raise exception 'تصفير البيانات متاح لمالك النشاط فقط';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select jsonb_build_object(
  'products',(select count(*) from public.products where business_id=p_business_id),
  'parties',(select count(*) from public.parties where business_id=p_business_id),
  'purchase_invoices',(select count(*) from public.purchase_invoices where business_id=p_business_id),
  'sales_invoices',(select count(*) from public.sales_invoices where business_id=p_business_id),
  'returns',(select count(*) from public.sales_returns where business_id=p_business_id),
  'payments',(select count(*) from public.payments where business_id=p_business_id),
  'stock_movements',(select count(*) from public.stock_movements where business_id=p_business_id),
  'expenses',(select count(*) from public.expenses where business_id=p_business_id),
  'cash_transactions',(select count(*) from public.cash_transactions where business_id=p_business_id),
  'purchase_cost_snapshots',(select count(*) from public.purchase_invoice_cost_snapshots where business_id=p_business_id),
  'stock_cost_snapshots',(select count(*) from public.stock_adjustment_cost_snapshots where business_id=p_business_id)
 ) into v_counts;
 -- Cash rows reference standalone payment rows; remove cash reversals and originals first.
 delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;
 delete from public.cash_transactions where business_id=p_business_id;
 -- Payment reversals reference original payments; remove reversals before originals.
 delete from public.payments where business_id=p_business_id and reversal_of_payment_id is not null;
 delete from public.payments where business_id=p_business_id;
 delete from public.sales_return_items where business_id=p_business_id;
 delete from public.expenses where business_id=p_business_id;
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
