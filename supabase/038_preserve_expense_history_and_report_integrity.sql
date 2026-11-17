
-- Preserve expense history when reversing its cash impact.
alter table public.expenses
 add column if not exists status text not null default 'posted',
 add column if not exists voided_at timestamptz,
 add column if not exists voided_by uuid references auth.users(id);
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.expenses'::regclass and conname='expenses_status_check') then
  alter table public.expenses add constraint expenses_status_check check(status in ('posted','void'));
 end if;
end $$;
create unique index if not exists expenses_cash_transaction_id_unique
 on public.expenses(cash_transaction_id) where cash_transaction_id is not null;

CREATE OR REPLACE FUNCTION public.owner_remove_expense(p_business_id uuid, p_expense_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_exp record; v_cash record; v_balance numeric(14,2); v_reversal_id uuid;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can remove expenses'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_exp from public.expenses
 where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'Expense not found'; end if;
 if v_exp.status='void' then raise exception 'Expense has already been cancelled'; end if;
 if v_exp.cash_transaction_id is null then
  raise exception 'This older expense has no verified cash link and cannot be safely removed';
 end if;
 select * into v_cash from public.cash_transactions
 where id=v_exp.cash_transaction_id and business_id=p_business_id for update;
 if not found or v_cash.transaction_type<>'expense' or v_cash.direction<>'out'
    or v_cash.amount<>v_exp.amount
    or v_cash.transaction_date<>v_exp.expense_date
    or v_cash.reason is distinct from v_exp.name
    or v_cash.invoice_id is not null or v_cash.party_id is not null
    or v_cash.sales_return_id is not null
    or v_cash.reversal_of_transaction_id is not null then
  raise exception 'The linked cash movement does not match this expense; no changes were made';
 end if;
 if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_cash.id) then
  raise exception 'This expense cash movement has already been reversed';
 end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
 into v_balance from public.cash_transactions where business_id=p_business_id;
 insert into public.cash_transactions(
  business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,reversal_of_transaction_id
 ) values(
  p_business_id,current_date,'in','deposit',v_exp.amount,'عكس حذف مصروف: '||v_exp.name,
  'عكس حركة المصروف المحذوف رقم '||p_expense_id,auth.uid(),v_cash.id
 ) returning id into v_reversal_id;
 update public.expenses
 set status='void',voided_at=clock_timestamp(),voided_by=auth.uid()
 where id=p_expense_id and business_id=p_business_id and status='posted';
 if not found then raise exception 'Expense was changed before cancellation'; end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void_reversed','expense',p_expense_id,
  jsonb_build_object('amount',v_exp.amount,'cash_transaction_id',v_cash.id,'reversal_id',v_reversal_id));
 return 'voided_reversed';
end;
$function$
;

create or replace view public.daily_business_summary
with (security_invoker=true)
as
 WITH report_dates AS (
         SELECT sales_invoices.business_id,
            sales_invoices.invoice_date AS report_date
           FROM sales_invoices
          WHERE sales_invoices.status <> 'void'::text
        UNION
         SELECT purchase_invoices.business_id,
            purchase_invoices.invoice_date
           FROM purchase_invoices
          WHERE purchase_invoices.status <> 'void'::text
        UNION
         SELECT expenses.business_id,
            expenses.expense_date
           FROM expenses
          WHERE expenses.status <> 'void'::text
        UNION
         SELECT cash_transactions.business_id,
            cash_transactions.transaction_date
           FROM cash_transactions
        UNION
         SELECT p_1.business_id,
            p_1.payment_date
           FROM payments p_1
          WHERE (p_1.invoice_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_invoices si
                  WHERE si.id = p_1.invoice_id AND si.business_id = p_1.business_id AND si.status <> 'void'::text)) OR (EXISTS ( SELECT 1
                   FROM purchase_invoices pi
                  WHERE pi.id = p_1.invoice_id AND pi.business_id = p_1.business_id AND pi.status <> 'void'::text))) AND (p_1.sales_return_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_returns sr
                  WHERE sr.id = p_1.sales_return_id AND sr.business_id = p_1.business_id AND sr.status <> 'void'::text)))
        )
 SELECT d.business_id,
    d.report_date,
    COALESCE(s.sales_total, 0::numeric)::numeric(14,2) AS sales_total,
    COALESCE(pay.sales_collected, 0::numeric)::numeric(14,2) AS sales_collected,
    COALESCE(s.sales_due, 0::numeric)::numeric(14,2) AS sales_outstanding,
    COALESCE(p.purchase_total, 0::numeric)::numeric(14,2) AS purchases_total,
    COALESCE(pay.purchases_paid, 0::numeric)::numeric(14,2) AS purchases_paid,
    COALESCE(e.expenses_total, 0::numeric)::numeric(14,2) AS expenses_total,
    COALESCE(c.cash_in, 0::numeric)::numeric(14,2) AS cash_in,
    COALESCE(c.cash_out, 0::numeric)::numeric(14,2) AS cash_out
   FROM report_dates d
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS sales_total,
            sum(x.due_total) AS sales_due
           FROM sales_invoices x
          WHERE x.business_id = d.business_id AND x.invoice_date = d.report_date AND x.status <> 'void'::text) s ON true
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS purchase_total
           FROM purchase_invoices x
          WHERE x.business_id = d.business_id AND x.invoice_date = d.report_date AND x.status <> 'void'::text) p ON true
     LEFT JOIN LATERAL ( SELECT sum(x.amount) AS expenses_total
           FROM expenses x
          WHERE x.business_id = d.business_id AND x.expense_date = d.report_date AND x.status <> 'void'::text) e ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text AND x.sales_return_id IS NULL AND (EXISTS ( SELECT 1
                       FROM sales_invoices si
                      WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.status <> 'void'::text)) THEN x.amount
                    ELSE 0::numeric
                END) AS sales_collected,
            sum(
                CASE
                    WHEN x.direction = 'out'::text AND (EXISTS ( SELECT 1
                       FROM purchase_invoices pi
                      WHERE pi.id = x.invoice_id AND pi.business_id = x.business_id AND pi.status <> 'void'::text)) THEN x.amount
                    ELSE 0::numeric
                END) AS purchases_paid
           FROM payments x
          WHERE x.business_id = d.business_id AND x.payment_date = d.report_date AND (x.sales_return_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_returns sr
                  WHERE sr.id = x.sales_return_id AND sr.business_id = x.business_id AND sr.status <> 'void'::text)))) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text THEN x.amount
                    ELSE 0::numeric
                END) AS cash_in,
            sum(
                CASE
                    WHEN x.direction = 'out'::text THEN x.amount
                    ELSE 0::numeric
                END) AS cash_out
           FROM cash_transactions x
          WHERE x.business_id = d.business_id AND x.transaction_date = d.report_date) c ON true;;

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
  'stock_adjustment_cost_snapshots','cash_transactions','expenses','business_settings','audit_log'
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
  if tbl='audit_log' and p_backup->'tables'->tbl is null then
   continue;
  end if;
  if jsonb_typeof(p_backup->'tables'->tbl) is distinct from 'array' then
   raise exception 'ملف النسخة الاحتياطية ناقص بيانات الجدول %',tbl;
  end if;
  if exists(select 1 from jsonb_array_elements(p_backup->'tables'->tbl) as rows(value)
    where value->>'business_id' is distinct from p_business_id::text) then
   raise exception 'النسخة تحتوي سجلات لا تخص هذا النشاط في الجدول %',tbl;
  end if;
  if tbl='audit_log' then
   select count(*) into row_count from public.audit_log
   where business_id=p_business_id and action<>'business_data_reset';
  else
   execute format('select count(*) from public.%I where business_id=$1',tbl) into row_count using p_business_id;
  end if;
  if row_count>0 then raise exception 'لا يمكن الاستعادة فوق بيانات موجودة. الجدول % يحتوي بالفعل على سجلات.',tbl; end if;
 end loop;

 foreach tbl in array required_tables loop
  if tbl='audit_log' then
   if p_backup->'tables'->tbl is null then continue; end if;
   if jsonb_array_length(p_backup->'tables'->tbl)>0 then
    insert into public.audit_log select * from jsonb_populate_recordset(null::public.audit_log,p_backup->'tables'->tbl);
   end if;
  elsif tbl='expenses' then
   select coalesce(jsonb_agg(value || jsonb_build_object(
    'status',coalesce(nullif(value->>'status',''),'posted')
   )),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
   if jsonb_array_length(v_rows)>0 then
    insert into public.expenses select * from jsonb_populate_recordset(null::public.expenses,v_rows);
   end if;
  elsif tbl='payments' then
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
