CREATE OR REPLACE FUNCTION public.reset_business_data(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

 delete from public.sales_return_items where business_id=p_business_id;
 delete from public.payments where business_id=p_business_id and reversal_of_payment_id is not null;
 delete from public.payments where business_id=p_business_id;
 delete from public.expenses where business_id=p_business_id;
 delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;
 delete from public.cash_transactions where business_id=p_business_id;
 delete from public.sales_returns where business_id=p_business_id;
 delete from public.purchase_invoice_cost_snapshots where business_id=p_business_id;
 delete from public.stock_adjustment_cost_snapshots where business_id=p_business_id;
 delete from public.stock_movements
 where business_id=p_business_id and reversal_of_movement_id is not null;
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
$function$
;

CREATE OR REPLACE FUNCTION public.restore_business_backup(p_business_id uuid, p_backup jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 tbl text;
 row_count bigint;
 v_rows jsonb;
 required_tables text[]:=array[
  'products','parties','purchase_invoices','purchase_items',
  'purchase_invoice_cost_snapshots','sales_invoices','sales_items',
  'sales_returns','sales_return_items','payments','stock_movements',
  'stock_adjustment_cost_snapshots','cash_transactions','expenses','business_settings'
 ];
begin
 if auth.uid() is null then raise exception 'يجب تسجيل الدخول لاستعادة النسخة الاحتياطية'; end if;
 if not exists(select 1 from public.business_members where business_id=p_business_id
  and user_id=auth.uid() and active=true and role='owner') then
  raise exception 'استعادة النسخة الاحتياطية متاحة لمالك النشاط فقط';
 end if;
 if jsonb_typeof(p_backup) is distinct from 'object'
  or p_backup->>'format_version' is distinct from 'alnesr-business-backup-v2'
  or p_backup->>'business_id' is distinct from p_business_id::text
  or jsonb_typeof(p_backup->'tables') is distinct from 'object' then
  raise exception 'ملف النسخة الاحتياطية غير صالح أو تابع لنشاط آخر';
 end if;
 foreach tbl in array required_tables loop
  if jsonb_typeof(p_backup->'tables'->tbl) is distinct from 'array' then
   raise exception 'ملف النسخة الاحتياطية ناقص بيانات الجدول %',tbl;
  end if;
  if exists(select 1 from jsonb_array_elements(p_backup->'tables'->tbl) as rows(value)
    where value->>'business_id' is distinct from p_business_id::text) then
   raise exception 'النسخة تحتوي سجلات لا تخص هذا النشاط في الجدول %',tbl;
  end if;
  execute format('select count(*) from public.%I where business_id=$1',tbl) into row_count using p_business_id;
  if row_count>0 then raise exception 'لا يمكن الاستعادة فوق بيانات موجودة. الجدول % يحتوي بالفعل على سجلات.',tbl; end if;
 end loop;

 foreach tbl in array required_tables loop
  if tbl='payments' then
   select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
     coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_payment_id','') is null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.payments select * from jsonb_populate_recordset(null::public.payments,v_rows);
   end if;
   select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
     coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_payment_id','') is not null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.payments select * from jsonb_populate_recordset(null::public.payments,v_rows);
   end if;
  elsif tbl='sales_returns' then
   select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
     coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
   if jsonb_array_length(v_rows)>0 then
    insert into public.sales_returns select * from jsonb_populate_recordset(null::public.sales_returns,v_rows);
   end if;
  elsif tbl='stock_movements' then
   select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
     coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_movement_id','') is null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.stock_movements select * from jsonb_populate_recordset(null::public.stock_movements,v_rows);
   end if;
   select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
     coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_movement_id','') is not null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.stock_movements select * from jsonb_populate_recordset(null::public.stock_movements,v_rows);
   end if;
  elsif tbl='cash_transactions' then
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_transaction_id','') is null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.cash_transactions select * from jsonb_populate_recordset(null::public.cash_transactions,v_rows);
   end if;
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_transaction_id','') is not null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.cash_transactions select * from jsonb_populate_recordset(null::public.cash_transactions,v_rows);
   end if;
  elsif jsonb_array_length(p_backup->'tables'->tbl)>0 then
   execute format('insert into public.%I select * from jsonb_populate_recordset(null::public.%I,$1)',tbl,tbl)
   using p_backup->'tables'->tbl;
  end if;
 end loop;
 return jsonb_build_object('restored',true,'business_id',p_business_id,'tables',to_jsonb(required_tables));
end;
$function$
;
