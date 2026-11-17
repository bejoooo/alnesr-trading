-- 031: Preserve payment history and align reversals, account statements, summaries, reset and restore.
-- This file mirrors the already-applied changes in the test database.

CREATE OR REPLACE FUNCTION public.owner_void_invoice(p_business_id uuid, p_invoice_type text, p_invoice_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_invoice record;
 v_cash_total numeric(14,2) := 0;
 v_cash_balance numeric(14,2) := 0;
 v_payment record;
 v_cash_tx record;
 v_payment_cash numeric(14,2) := 0;
 v_cash_ledger numeric(14,2) := 0;
 v_payment_reversal_id uuid;
 v_cash_reversal_id uuid;
begin
 if auth.uid() is null or not exists (
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid()
    and role='owner' and active
 ) then
  raise exception 'Only the active business owner can cancel invoices';
 end if;
 if p_invoice_type not in ('sale','purchase') then
  raise exception 'Unsupported invoice type';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

 if p_invoice_type='sale' then
  select * into v_invoice from public.sales_invoices
  where id=p_invoice_id and business_id=p_business_id for update;
 else
  select * into v_invoice from public.purchase_invoices
  where id=p_invoice_id and business_id=p_business_id for update;
 end if;
 if not found then raise exception 'Invoice not found in this business'; end if;
 if v_invoice.status='void' then raise exception 'Invoice is already cancelled'; end if;

 if p_invoice_type='sale' then
  if exists(select 1 from public.sales_returns
    where business_id=p_business_id and sales_invoice_id=p_invoice_id and status<>'void') then
   raise exception 'Cannot cancel an invoice with active returns; cancel the returns first';
  end if;
  if exists(
   select 1 from public.stock_movements m
   join public.sales_items i on i.business_id=m.business_id and i.product_id=m.product_id
   where m.business_id=p_business_id and i.invoice_id=p_invoice_id
    and m.created_at>(select created_at from public.sales_invoices where id=p_invoice_id)
    and not (m.source_type='sale' and m.source_id=p_invoice_id)
  ) then
   raise exception 'Cannot cancel this sale: later stock movements exist for one or more products';
  end if;
 else
  if exists(
   select 1 from public.stock_movements m
   join public.purchase_items i on i.business_id=m.business_id and i.product_id=m.product_id
   where m.business_id=p_business_id and i.invoice_id=p_invoice_id
    and m.created_at>(select created_at from public.purchase_invoices where id=p_invoice_id)
    and not (m.source_type='purchase' and m.source_id=p_invoice_id)
  ) then
   raise exception 'Cannot cancel this purchase: later stock movements exist for one or more products';
  end if;
  if exists(
   select 1 from public.purchase_items i
   left join public.purchase_invoice_cost_snapshots s
    on s.business_id=i.business_id and s.invoice_id=i.invoice_id and s.product_id=i.product_id
   where i.business_id=p_business_id and i.invoice_id=p_invoice_id and s.product_id is null
  ) then
   raise exception 'This older purchase has no cost snapshot and cannot be safely cancelled';
  end if;
 end if;

 -- Payment history is immutable: verify that cash payment rows match their cash-ledger rows.
 if p_invoice_type='sale' then
  select coalesce(sum(amount),0) into v_payment_cash
  from public.payments
  where business_id=p_business_id and invoice_id=p_invoice_id
    and direction='in' and lower(method)='cash' and sales_return_id is null and reversal_of_payment_id is null;
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='sale_payment' and direction='in'
    and reversal_of_transaction_id is null;
 else
  select coalesce(sum(amount),0) into v_payment_cash
  from public.payments
  where business_id=p_business_id and invoice_id=p_invoice_id
    and direction='out' and lower(method)='cash' and sales_return_id is null and reversal_of_payment_id is null;
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='purchase_payment' and direction='out'
    and reversal_of_transaction_id is null;
 end if;
 if v_payment_cash<>v_cash_ledger then
  raise exception 'Cash payment history does not reconcile with the cash ledger; invoice was not changed';
 end if;
 v_cash_total:=v_cash_ledger;

 if p_invoice_type='sale' then
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_cash_balance from public.cash_transactions where business_id=p_business_id;
  if v_cash_total>v_cash_balance then
   raise exception 'Cash balance is insufficient to reverse cash receipts. Record a cash deposit first.';
  end if;
 end if;

 -- Reverse each payment row rather than deleting it, including non-cash payments.
 for v_payment in
  select p.* from public.payments p
  where p.business_id=p_business_id and p.invoice_id=p_invoice_id
    and p.sales_return_id is null
    and p.reversal_of_payment_id is null
    and not exists(select 1 from public.payments pr where pr.reversal_of_payment_id=p.id)
  order by p.created_at,p.id for update
 loop
  insert into public.payments(
   business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,
   notes,created_by,reversal_of_payment_id
  ) values(
   p_business_id,v_payment.party_id,p_invoice_id,
   case when v_payment.direction='in' then 'out' else 'in' end,
   v_payment.amount,current_date,v_payment.method,
   'عكس دفعة '||coalesce(v_payment.reference,v_payment.id::text),
   'قيد عكسي لدفعة فاتورة ملغاة',auth.uid(),v_payment.id
  ) returning id into v_payment_reversal_id;
 end loop;

 -- Reverse each original cash movement with a traceable one-to-one pointer.
 for v_cash_tx in
  select * from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type=case when p_invoice_type='sale' then 'sale_payment' else 'purchase_payment' end
    and reversal_of_transaction_id is null
  order by created_at,id for update
 loop
  insert into public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id
  ) values(
   p_business_id,current_date,
   case when v_cash_tx.direction='in' then 'out' else 'in' end,
   case when v_cash_tx.direction='in' then 'other' else 'deposit' end,
   v_cash_tx.amount,v_cash_tx.party_id,p_invoice_id,
   'عكس حركة دفعة فاتورة ملغاة',
   'عكس حركة الخزنة الأصلية رقم '||v_cash_tx.id,auth.uid(),v_cash_tx.id
  ) returning id into v_cash_reversal_id;
 end loop;

 if p_invoice_type='sale' then
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by
  )
  select business_id,product_id,current_date,'adjustment_in',quantity,unit_cost_snapshot,
   'sale_void',p_invoice_id,'عكس مخزون فاتورة مبيعات ملغاة',auth.uid()
  from public.sales_items where business_id=p_business_id and invoice_id=p_invoice_id;
  update public.sales_invoices set status='void',paid_total=0,due_total=0
   where id=p_invoice_id and business_id=p_business_id;
 else
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by
  )
  select business_id,product_id,current_date,'adjustment_out',-quantity,unit_landed_cost,
   'purchase_void',p_invoice_id,'عكس مخزون فاتورة مشتريات ملغاة',auth.uid()
  from public.purchase_items where business_id=p_business_id and invoice_id=p_invoice_id;
  update public.products p set average_cost=s.average_cost_before,updated_at=now()
   from public.purchase_invoice_cost_snapshots s
   where s.business_id=p_business_id and s.invoice_id=p_invoice_id
     and p.id=s.product_id and p.business_id=p_business_id;
  update public.purchase_invoices set status='void',paid_total=0,due_total=0
   where id=p_invoice_id and business_id=p_business_id;
 end if;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void',p_invoice_type||'_invoice',p_invoice_id,
  jsonb_build_object('invoice_no',v_invoice.invoice_no,'cash_reversed',v_cash_total,
   'payment_history_preserved',true));
 return 'void';
end;
$function$


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
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_payment_id','') is null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.payments select * from jsonb_populate_recordset(null::public.payments,v_rows);
   end if;
   select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
   from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
   where nullif(value->>'reversal_of_payment_id','') is not null;
   if jsonb_array_length(v_rows)>0 then
    insert into public.payments select * from jsonb_populate_recordset(null::public.payments,v_rows);
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


create or replace view public.party_account_balances
with (security_invoker = true) as
 SELECT p.business_id,
    p.id AS party_id,
    p.kind,
    p.name,
    p.phone,
    p.opening_balance,
    COALESCE(s.sales_total, 0::numeric)::numeric(14,2) AS sales_total,
    COALESCE(pi.purchases_total, 0::numeric)::numeric(14,2) AS purchases_total,
    COALESCE(pay.customer_paid, 0::numeric)::numeric(14,2) AS customer_payments,
    COALESCE(pay.supplier_paid, 0::numeric)::numeric(14,2) AS supplier_payments,
    COALESCE(r.returns_total, 0::numeric)::numeric(14,2) AS returns_total,
        CASE
            WHEN p.kind = ANY (ARRAY['customer'::text, 'both'::text]) THEN
            CASE
                WHEN p.opening_balance_side = 'receivable'::text THEN p.opening_balance
                ELSE 0::numeric
            END + COALESCE(s.sales_total, 0::numeric) - COALESCE(pay.customer_paid, 0::numeric) - COALESCE(r.returns_total, 0::numeric) + COALESCE(pay.customer_refunds, 0::numeric)
            ELSE 0::numeric
        END::numeric(14,2) AS customer_net_balance,
        CASE
            WHEN p.kind = ANY (ARRAY['supplier'::text, 'both'::text]) THEN
            CASE
                WHEN p.opening_balance_side = 'payable'::text THEN p.opening_balance
                ELSE 0::numeric
            END + COALESCE(pi.purchases_total, 0::numeric) - COALESCE(pay.supplier_paid, 0::numeric)
            ELSE 0::numeric
        END::numeric(14,2) AS supplier_net_balance,
    p.opening_balance_side
   FROM parties p
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS sales_total
           FROM sales_invoices x
          WHERE x.business_id = p.business_id AND x.customer_id = p.id AND x.status <> 'void'::text) s ON true
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS purchases_total
           FROM purchase_invoices x
          WHERE x.business_id = p.business_id AND x.supplier_id = p.id AND x.status <> 'void'::text) pi ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text AND (EXISTS ( SELECT 1
                       FROM sales_invoices si
                      WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.customer_id = p.id)) THEN x.amount
                    ELSE 0::numeric
                END) AS customer_paid,
            sum(
                CASE
                    WHEN x.direction = 'out'::text AND (EXISTS ( SELECT 1
                       FROM purchase_invoices px
                      WHERE px.id = x.invoice_id AND px.business_id = x.business_id AND px.supplier_id = p.id)) THEN x.amount
                    WHEN x.direction = 'in'::text AND (EXISTS ( SELECT 1
                       FROM purchase_invoices px
                      WHERE px.id = x.invoice_id AND px.business_id = x.business_id AND px.supplier_id = p.id)) THEN - x.amount
                    ELSE 0::numeric
                END) AS supplier_paid,
            sum(
                CASE
                    WHEN x.direction = 'out'::text AND (EXISTS ( SELECT 1
                       FROM sales_invoices si
                      WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.customer_id = p.id)) THEN x.amount
                    ELSE 0::numeric
                END) AS customer_refunds
           FROM payments x
          WHERE x.business_id = p.business_id AND x.party_id = p.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(x.refund_total) AS returns_total
           FROM sales_returns x
          WHERE x.business_id = p.business_id AND x.customer_id = p.id AND x.status <> 'void'::text) r ON true;;

create or replace view public.party_account_statement
with (security_invoker = true) as
 SELECT p.business_id,
    p.id AS party_id,
    p.name AS party_name,
    'opening_balance'::text AS entry_type,
    NULL::uuid AS entry_id,
    NULL::text AS reference_no,
    p.created_at::date AS entry_date,
        CASE
            WHEN p.opening_balance_side = 'receivable'::text THEN p.opening_balance
            ELSE 0::numeric
        END::numeric(14,2) AS debit,
        CASE
            WHEN p.opening_balance_side = 'payable'::text THEN p.opening_balance
            ELSE 0::numeric
        END::numeric(14,2) AS credit,
    'رصيد افتتاحي'::text AS description
   FROM parties p
  WHERE p.opening_balance <> 0::numeric
UNION ALL
 SELECT i.business_id,
    i.customer_id AS party_id,
    p.name AS party_name,
    'sale_invoice'::text AS entry_type,
    i.id AS entry_id,
    i.invoice_no AS reference_no,
    i.invoice_date AS entry_date,
    i.total AS debit,
    0::numeric AS credit,
    'فاتورة مبيعات'::text AS description
   FROM sales_invoices i
     JOIN parties p ON p.id = i.customer_id AND p.business_id = i.business_id
  WHERE i.customer_id IS NOT NULL AND i.status <> 'void'::text
UNION ALL
 SELECT i.business_id,
    i.supplier_id AS party_id,
    p.name AS party_name,
    'purchase_invoice'::text AS entry_type,
    i.id AS entry_id,
    i.invoice_no AS reference_no,
    i.invoice_date AS entry_date,
    0::numeric AS debit,
    i.total AS credit,
    'فاتورة مشتريات'::text AS description
   FROM purchase_invoices i
     JOIN parties p ON p.id = i.supplier_id AND p.business_id = i.business_id
  WHERE i.supplier_id IS NOT NULL AND i.status <> 'void'::text
UNION ALL
 SELECT x.business_id,
    x.party_id,
    p.name AS party_name,
    'payment'::text AS entry_type,
    x.id AS entry_id,
    x.reference AS reference_no,
    x.payment_date AS entry_date,
        CASE
            WHEN x.direction = 'out'::text THEN x.amount
            ELSE 0::numeric
        END AS debit,
        CASE
            WHEN x.direction = 'in'::text THEN x.amount
            ELSE 0::numeric
        END AS credit,
    COALESCE(x.notes, 'دفعة'::text) AS description
   FROM payments x
     JOIN parties p ON p.id = x.party_id AND p.business_id = x.business_id
  WHERE x.party_id IS NOT NULL
UNION ALL
 SELECT r.business_id,
    r.customer_id AS party_id,
    p.name AS party_name,
    'sales_return'::text AS entry_type,
    r.id AS entry_id,
    r.return_no AS reference_no,
    r.return_date AS entry_date,
    0::numeric AS debit,
    r.refund_total AS credit,
    'مرتجع مبيعات'::text AS description
   FROM sales_returns r
     JOIN parties p ON p.id = r.customer_id AND p.business_id = r.business_id
  WHERE r.customer_id IS NOT NULL AND r.status <> 'void'::text;;

create or replace view public.daily_business_summary
with (security_invoker = true) as
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
        UNION
         SELECT cash_transactions.business_id,
            cash_transactions.transaction_date
           FROM cash_transactions
        UNION
         SELECT p_1.business_id,
            p_1.payment_date
           FROM payments p_1
          WHERE p_1.invoice_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_invoices si
                  WHERE si.id = p_1.invoice_id AND si.business_id = p_1.business_id AND si.status <> 'void'::text)) OR (EXISTS ( SELECT 1
                   FROM purchase_invoices pi
                  WHERE pi.id = p_1.invoice_id AND pi.business_id = p_1.business_id AND pi.status <> 'void'::text))
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
          WHERE x.business_id = d.business_id AND x.expense_date = d.report_date) e ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text AND (EXISTS ( SELECT 1
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
          WHERE x.business_id = d.business_id AND x.payment_date = d.report_date) pay ON true
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

do $$
begin
 if not exists(select 1 from pg_constraint
  where conrelid='public.payments'::regclass
   and conname='payments_method_supported_check') then
  alter table public.payments add constraint payments_method_supported_check
   check (lower(btrim(method)) = any (array['cash','bank_transfer','instapay','other']::text[]));
 end if;
end $$;

revoke all on function public.owner_void_invoice(uuid,text,uuid) from public,anon;
grant execute on function public.owner_void_invoice(uuid,text,uuid) to authenticated;
revoke all on function public.reset_business_data(uuid) from public,anon;
grant execute on function public.reset_business_data(uuid) to authenticated;
revoke all on function public.restore_business_backup(uuid,jsonb) from public,anon;
grant execute on function public.restore_business_backup(uuid,jsonb) to authenticated;
