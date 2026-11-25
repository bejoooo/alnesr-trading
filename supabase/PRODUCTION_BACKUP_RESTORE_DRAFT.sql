-- DRAFT ONLY — hardened backup restore RPC (v2/v3 compatibility)
-- Extracted from Test, then hardened for missing legacy columns and null version.
-- This file defines the RPC; it does not execute a restore or reset business data.

begin;
set local search_path = pg_catalog, public, storage;

do $preflight$
declare v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name) into v_missing
  from (values
    ('public.business_members'),('public.businesses'),('public.products'),('public.parties'),
    ('public.purchase_invoices'),('public.purchase_items'),('public.purchase_invoice_cost_snapshots'),
    ('public.sales_invoices'),('public.sales_items'),('public.sales_returns'),('public.sales_return_items'),
    ('public.purchase_returns'),('public.purchase_return_items'),('public.payments'),
    ('public.customer_credit_ledger'),('public.stock_movements'),('public.stock_adjustment_cost_snapshots'),
    ('public.treasury_transfers'),('public.cash_transactions'),('public.expenses'),
    ('public.business_settings'),('public.audit_log')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing restore dependency tables: %',array_to_string(v_missing,', ');
  end if;

  if exists (
    select 1 from (values
      ('sales_returns','status'),('sales_returns','posted_at'),
      ('sales_return_items','unit_price'),('sales_items','unit_price'),
      ('stock_movements','posted_at'),('stock_movements','stock_bucket'),
      ('cash_transactions','account_method'),('payments','posted_at'),('expenses','status')
    ) as required(table_name,column_name)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name=required.table_name
        and c.column_name=required.column_name
    )
  ) then
    raise exception 'Missing restore dependency columns';
  end if;

  -- This trigger mutates product average_cost from the current value while replaying
  -- customer-return movements. Restore must preserve the exported final product cost
  -- and the movement's historical average_cost_before instead.
  if not exists (
    select 1 from pg_trigger t
    where t.tgrelid='public.stock_movements'::regclass
      and t.tgname='stock_movements_customer_return_average_cost'
      and not t.tgisinternal and t.tgenabled='O'
  ) then
    raise exception 'Required customer-return average-cost trigger is missing or disabled';
  end if;

  -- Restore depends on validated same-business composite FKs from the structural
  -- hardening stage; otherwise a crafted backup could reference another tenant's row.
  if exists (
    select 1
    from (values
      ('payments','payments_reversal_same_business_fk'),
      ('cash_transactions','cash_payment_same_business_fk'),
      ('cash_transactions','cash_transfer_same_business_fk'),
      ('cash_transactions','cash_reversal_same_business_fk'),
      ('expenses','expense_cash_same_business_fk'),
      ('stock_movements','stock_reversal_same_business_fk'),
      ('purchase_returns','purchase_return_invoice_same_business_fk'),
      ('purchase_returns','purchase_return_supplier_same_business_fk'),
      ('purchase_return_items','purchase_return_item_parent_same_business_fk'),
      ('purchase_return_items','purchase_return_item_source_same_business_fk'),
      ('purchase_return_items','purchase_return_item_product_same_business_fk'),
      ('customer_credit_ledger','customer_credit_party_same_business_fk'),
      ('customer_credit_ledger','customer_credit_return_same_business_fk'),
      ('customer_credit_ledger','customer_credit_invoice_same_business_fk'),
      ('customer_credit_ledger','customer_credit_payment_same_business_fk'),
      ('customer_credit_ledger','customer_credit_reversal_same_business_fk'),
      ('purchase_invoice_cost_snapshots','purchase_cost_snapshot_invoice_same_business_fk'),
      ('purchase_invoice_cost_snapshots','purchase_cost_snapshot_product_same_business_fk'),
      ('stock_adjustment_cost_snapshots','stock_cost_snapshot_movement_same_business_fk'),
      ('stock_adjustment_cost_snapshots','stock_cost_snapshot_product_same_business_fk')
    ) required(table_name,constraint_name)
    where not exists (
      select 1 from pg_constraint pc
      where pc.connamespace='public'::regnamespace
        and pc.conrelid=format('public.%I',required.table_name)::regclass
        and pc.conname=required.constraint_name
        and pc.contype='f' and pc.convalidated
    )
  ) then
    raise exception 'Required validated same-business foreign keys are missing; apply the structural FK stage first';
  end if;
end
$preflight$;


CREATE OR REPLACE FUNCTION public.restore_business_backup(p_business_id uuid, p_backup jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  tbl text;
  row_count bigint;
  v_rows jsonb;
  v_backup_version text;
  required_tables text[] := array[
    'products','parties','purchase_invoices','purchase_items',
    'purchase_invoice_cost_snapshots','sales_invoices','sales_items',
    'sales_returns','sales_return_items','purchase_returns','purchase_return_items',
    'payments','customer_credit_ledger','stock_movements',
    'stock_adjustment_cost_snapshots','treasury_transfers','cash_transactions','expenses',
    'business_settings','audit_log'
  ];
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول لاستعادة النسخة الاحتياطية';
  end if;

  perform 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid()
    and active=true and role='owner'
  for share;
  if not found then
    raise exception 'استعادة النسخة الاحتياطية متاحة لمالك النشاط فقط';
  end if;

  if jsonb_typeof(p_backup) is distinct from 'object'
     or p_backup->>'business_id' is distinct from p_business_id::text
     or jsonb_typeof(p_backup->'tables') is distinct from 'object' then
    raise exception 'ملف النسخة الاحتياطية غير صالح أو تابع لنشاط آخر';
  end if;
  v_backup_version:=p_backup->>'format_version';
  if v_backup_version is null
     or v_backup_version not in ('alnesr-business-backup-v2','alnesr-business-backup-v3') then
    raise exception 'إصدار النسخة الاحتياطية غير مدعوم';
  end if;
  if v_backup_version='alnesr-business-backup-v2' then
    -- Older backups predate these tables; preserve compatibility but restore them as empty.
    p_backup:=jsonb_set(p_backup,'{tables,purchase_returns}','[]'::jsonb,true);
    p_backup:=jsonb_set(p_backup,'{tables,purchase_return_items}','[]'::jsonb,true);
    p_backup:=jsonb_set(p_backup,'{tables,customer_credit_ledger}','[]'::jsonb,true);
    p_backup:=jsonb_set(p_backup,'{tables,treasury_transfers}','[]'::jsonb,true);
  end if;

  -- Use the same per-business lock as reset_business_data.
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

  -- Block new rows that reference this business while the empty-state check and restore run.
  perform 1 from public.businesses where id=p_business_id for update;
  if not found then
    raise exception 'النشاط المطلوب غير موجود';
  end if;

  foreach tbl in array required_tables loop
    if tbl='audit_log' and p_backup->'tables'->tbl is null then
      continue;
    end if;
    if jsonb_typeof(p_backup->'tables'->tbl) is distinct from 'array' then
      raise exception 'ملف النسخة الاحتياطية ناقص بيانات الجدول %',tbl;
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->tbl) as rows(value)
      where value->>'business_id' is distinct from p_business_id::text
    ) then
      raise exception 'النسخة تحتوي سجلات لا تخص هذا النشاط في الجدول %',tbl;
    end if;

    if tbl='audit_log' then
      select count(*) into row_count from public.audit_log
      where business_id=p_business_id and action<>'business_data_reset';
    else
      execute format('select count(*) from public.%I where business_id=$1',tbl)
        into row_count using p_business_id;
    end if;
    if row_count>0 then
      raise exception 'لا يمكن الاستعادة فوق بيانات موجودة. الجدول % يحتوي بالفعل على سجلات.',tbl;
    end if;
  end loop;

  -- Validate polymorphic and snapshot references that do not have composite FKs.
  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'purchase_invoice_cost_snapshots') s(value)
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') i(value)
      where i.value->>'id'=s.value->>'invoice_id'
        and i.value->>'business_id'=p_business_id::text
    ) or not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'products') p(value)
      where p.value->>'id'=s.value->>'product_id'
        and p.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'لقطات تكلفة المشتريات تحتوي مراجع خارج النشاط أو غير موجودة';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'stock_adjustment_cost_snapshots') s(value)
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'stock_movements') m(value)
      where m.value->>'id'=s.value->>'movement_id'
        and m.value->>'business_id'=p_business_id::text
    ) or not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'products') p(value)
      where p.value->>'id'=s.value->>'product_id'
        and p.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'لقطات تكلفة تسويات المخزون تحتوي مراجع خارج النشاط أو غير موجودة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_return_items') ri(value)
    where not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value) where r.value->>'id'=ri.value->>'return_id')
       or not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') i(value) where i.value->>'id'=ri.value->>'purchase_item_id')
       or not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'products') p(value) where p.value->>'id'=ri.value->>'product_id')
  ) then
    raise exception 'بنود مرتجعات المشتريات تحتوي مراجع غير موجودة في النسخة';
  end if;

  -- Reconcile persisted return totals with their detail rows before restoring.
  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value)
    where round(coalesce((select sum(nullif(i.value->>'line_total','')::numeric)
      from jsonb_array_elements(p_backup->'tables'->'purchase_return_items') i(value)
      where i.value->>'return_id'=r.value->>'id'),0),2)
      <> round(coalesce(nullif(r.value->>'total','')::numeric,0),2)
      or coalesce(nullif(r.value->>'invoice_due_reduced_total','')::numeric,0)
         > coalesce(nullif(r.value->>'total','')::numeric,0)
  ) then
    raise exception 'إجمالي مرتجع المشتريات أو تخفيض مستحق الفاتورة لا يطابق بنوده';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
    where round(coalesce((select sum(nullif(i.value->>'refund_amount','')::numeric)
      from jsonb_array_elements(p_backup->'tables'->'sales_return_items') i(value)
      where i.value->>'return_id'=r.value->>'id'),0),2)
      <> round(coalesce(nullif(r.value->>'refund_total','')::numeric,0),2)
      or coalesce(nullif(r.value->>'invoice_due_reduced_total','')::numeric,0)
         > coalesce(nullif(r.value->>'refund_total','')::numeric,0)
  ) then
    raise exception 'إجمالي مرتجع المبيعات أو تخفيض مستحق الفاتورة لا يطابق بنوده';
  end if;

  -- Enforce the same logical parent-child relationships as the posting RPCs.
  -- Same-business FKs alone do not prove that a return item belongs to the invoice
  -- referenced by its parent return, or that the returned product matches its source item.
  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value)
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') i(value)
      where i.value->>'id'=r.value->>'purchase_invoice_id'
        and i.value->>'supplier_id'=r.value->>'supplier_id'
        and i.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'مرتجع مشتريات مرتبط بمورد أو فاتورة غير متطابقين';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'purchase_return_items') ri(value)
    join jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value)
      on r.value->>'id'=ri.value->>'return_id'
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_items') pi(value)
      where pi.value->>'id'=ri.value->>'purchase_item_id'
        and pi.value->>'invoice_id'=r.value->>'purchase_invoice_id'
        and pi.value->>'product_id'=ri.value->>'product_id'
        and pi.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'بند مرتجع المشتريات لا يطابق فاتورة المرتجع أو المنتج الأصلي';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') i(value)
      where i.value->>'id'=r.value->>'sales_invoice_id'
        and i.value->>'customer_id'=r.value->>'customer_id'
        and i.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'مرتجع المبيعات مرتبط بعميل أو فاتورة غير متطابقين';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'sales_return_items') ri(value)
    join jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
      on r.value->>'id'=ri.value->>'return_id'
    where not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'sales_items') si(value)
      where si.value->>'id'=ri.value->>'sales_item_id'
        and si.value->>'invoice_id'=r.value->>'sales_invoice_id'
        and si.value->>'product_id'=ri.value->>'product_id'
        and si.value->>'business_id'=p_business_id::text
    )
  ) then
    raise exception 'بند مرتجع المبيعات لا يطابق فاتورة المرتجع أو المنتج المباع';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'customer_credit_ledger') c(value)
    where (nullif(c.value->>'source_return_id','') is not null and not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
      where r.value->>'id'=c.value->>'source_return_id'
        and r.value->>'customer_id'=c.value->>'customer_id'
    ))
    or (nullif(c.value->>'invoice_id','') is not null and not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') i(value)
      where i.value->>'id'=c.value->>'invoice_id'
        and i.value->>'customer_id'=c.value->>'customer_id'
    ))
    or (nullif(c.value->>'payment_id','') is not null and not exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
      where p.value->>'id'=c.value->>'payment_id'
        and p.value->>'party_id'=c.value->>'customer_id'
    ))
  ) then
    raise exception 'حركة رصيد العميل الدائن مرتبطة بمرتجع أو فاتورة أو دفعة تخص طرفًا آخر';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
    where nullif(p.value->>'purchase_return_id','') is not null
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value) where r.value->>'id'=p.value->>'purchase_return_id')
  ) then
    raise exception 'إحدى الدفعات مرتبطة بمرتجع مشتريات غير موجود في النسخة';
  end if;

  -- Polymorphic invoice/return references must agree with the actual party and direction.
  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
    where
      (nullif(p.value->>'sales_return_id','') is not null and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
        where r.value->>'id'=p.value->>'sales_return_id'
          and r.value->>'customer_id'=p.value->>'party_id'
          and r.value->>'sales_invoice_id'=p.value->>'invoice_id'
          and p.value->>'direction'='out'
      ))
      or
      (nullif(p.value->>'purchase_return_id','') is not null and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value)
        where r.value->>'id'=p.value->>'purchase_return_id'
          and r.value->>'supplier_id'=p.value->>'party_id'
          and r.value->>'purchase_invoice_id'=p.value->>'invoice_id'
          and p.value->>'direction'='in'
      ))
      or
      (nullif(p.value->>'invoice_id','') is not null and (
        (exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') i(value)
          where i.value->>'id'=p.value->>'invoice_id')
         and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') i(value)
          where i.value->>'id'=p.value->>'invoice_id' and i.value->>'customer_id'=p.value->>'party_id'))
        or
        (exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') i(value)
          where i.value->>'id'=p.value->>'invoice_id')
         and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') i(value)
          where i.value->>'id'=p.value->>'invoice_id' and i.value->>'supplier_id'=p.value->>'party_id'))
      ))
  ) then
    raise exception 'دفعة مرتبطة بفاتورة أو مرتجع يخص طرفًا آخر أو باتجاه غير صحيح';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
    where
      (nullif(c.value->>'sales_return_id','') is not null and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value)
        where r.value->>'id'=c.value->>'sales_return_id'
          and r.value->>'customer_id'=c.value->>'party_id'
          and r.value->>'sales_invoice_id'=c.value->>'invoice_id'
          and c.value->>'direction'='out'
      ))
      or
      (nullif(c.value->>'purchase_return_id','') is not null and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value)
        where r.value->>'id'=c.value->>'purchase_return_id'
          and r.value->>'supplier_id'=c.value->>'party_id'
          and r.value->>'purchase_invoice_id'=c.value->>'invoice_id'
          and c.value->>'direction'='in'
      ))
      or
      (nullif(c.value->>'payment_id','') is not null and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
        where p.value->>'id'=c.value->>'payment_id'
          and p.value->>'amount'=c.value->>'amount'
          and p.value->>'direction'=c.value->>'direction'
          and p.value->>'party_id' is not distinct from c.value->>'party_id'
          and lower(p.value->>'method')=lower(c.value->>'account_method')
          and lower(c.value->>'account_method')='cash'
      ))
  ) then
    raise exception 'حركة الخزنة لا تطابق الدفعة أو المرتجع المرتبط بها';
  end if;

  -- A cash leg must exist exactly once for each transfer touching the cash account;
  -- non-cash-only transfers must not create a cash transaction.
  if exists (
    select 1
    from jsonb_array_elements(p_backup->'tables'->'treasury_transfers') t(value)
    where (
      (t.value->>'source_method'='cash' or t.value->>'destination_method'='cash')
      and (select count(*) from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
        where c.value->>'treasury_transfer_id'=t.value->>'id'
          and c.value->>'amount'=t.value->>'amount'
          and c.value->>'account_method'='cash'
          and c.value->>'direction'=case when t.value->>'source_method'='cash' then 'out' else 'in' end)<>1
    ) or (
      t.value->>'source_method'<>'cash' and t.value->>'destination_method'<>'cash'
      and exists (select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
        where c.value->>'treasury_transfer_id'=t.value->>'id')
    ) or (
      nullif(t.value->>'reversal_of_transfer_id','') is not null
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'treasury_transfers') original(value)
        where original.value->>'id'=t.value->>'reversal_of_transfer_id'
          and original.value->>'source_method'=t.value->>'destination_method'
          and original.value->>'destination_method'=t.value->>'source_method'
          and original.value->>'amount'=t.value->>'amount')
    )
  ) then
    raise exception 'تحويل الخزنة أو حركته النقدية أو عكسه غير متطابق';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
    where nullif(p.value->>'invoice_id','') is not null
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') s(value)
        where s.value->>'id'=p.value->>'invoice_id'
      )
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') b(value)
        where b.value->>'id'=p.value->>'invoice_id'
      )
  ) then
    raise exception 'إحدى الدفعات مرتبطة بفاتورة غير موجودة في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
    where nullif(c.value->>'invoice_id','') is not null
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') s(value)
        where s.value->>'id'=c.value->>'invoice_id'
      )
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_invoices') b(value)
        where b.value->>'id'=c.value->>'invoice_id'
      )
  ) then
    raise exception 'إحدى حركات الخزنة مرتبطة بفاتورة غير موجودة في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
    where nullif(c.value->>'payment_id','') is not null
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value)
        where p.value->>'id'=c.value->>'payment_id'
          and p.value->>'business_id'=p_business_id::text
      )
  ) then
    raise exception 'إحدى حركات الخزنة مرتبطة بدفعة غير موجودة في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
    where nullif(c.value->>'purchase_return_id','') is not null
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'purchase_returns') r(value) where r.value->>'id'=c.value->>'purchase_return_id')
  ) then
    raise exception 'إحدى حركات الخزنة مرتبطة بمرتجع مشتريات غير موجود في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
    where nullif(c.value->>'treasury_transfer_id','') is not null
      and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'treasury_transfers') t(value) where t.value->>'id'=c.value->>'treasury_transfer_id')
  ) then
    raise exception 'إحدى حركات الخزنة مرتبطة بتحويل غير موجود في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'customer_credit_ledger') c(value)
    where (nullif(c.value->>'source_return_id','') is not null and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales_returns') r(value) where r.value->>'id'=c.value->>'source_return_id'))
       or (nullif(c.value->>'invoice_id','') is not null and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'sales_invoices') i(value) where i.value->>'id'=c.value->>'invoice_id'))
       or (nullif(c.value->>'payment_id','') is not null and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'payments') p(value) where p.value->>'id'=c.value->>'payment_id'))
       or (nullif(c.value->>'reversal_of_id','') is not null and not exists (select 1 from jsonb_array_elements(p_backup->'tables'->'customer_credit_ledger') original(value) where original.value->>'id'=c.value->>'reversal_of_id'))
  ) then
    raise exception 'سجل الرصيد الدائن يحتوي مراجع غير موجودة في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'expenses') e(value)
    where nullif(e.value->>'cash_transaction_id','') is not null
      and not exists (
        select 1 from jsonb_array_elements(p_backup->'tables'->'cash_transactions') c(value)
        where c.value->>'id'=e.value->>'cash_transaction_id'
          and c.value->>'business_id'=p_business_id::text
      )
  ) then
    raise exception 'إحدى المصروفات مرتبطة بحركة خزنة غير موجودة في النسخة';
  end if;

  if exists (
    select 1 from jsonb_array_elements(p_backup->'tables'->'products') p(value)
    where nullif(p.value->>'image_path','') is not null
      and (
        left(p.value->>'image_path',length(p_business_id::text)+1)<>p_business_id::text||'/'
        or not exists (
          select 1 from storage.objects o
          where o.bucket_id='product-images' and o.name=p.value->>'image_path'
        )
      )
  ) then
    raise exception 'صورة أحد المنتجات غير موجودة في التخزين الخاص أو لا تخص هذا النشاط';
  end if;

  -- Parent tables first; any error rolls the whole restore back.
  foreach tbl in array required_tables loop
    if tbl='audit_log' then
      if p_backup->'tables'->tbl is null then continue; end if;
      if jsonb_array_length(p_backup->'tables'->tbl)>0 then
        insert into public.audit_log
        select * from jsonb_populate_recordset(null::public.audit_log,p_backup->'tables'->tbl)
        on conflict (id) do nothing;
      end if;
    elsif tbl='parties' then
      -- Very old v2 exports may predate party archiving; such parties were active.
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'is_active',coalesce(nullif(value->>'is_active','')::boolean,true)
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
      if jsonb_array_length(v_rows)>0 then
        insert into public.parties
        select * from jsonb_populate_recordset(null::public.parties,v_rows);
      end if;
    elsif tbl='purchase_invoices' then
      -- Supplier-credit application did not exist in older v2 exports.
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'supplier_credit_applied_total',
        coalesce(nullif(value->>'supplier_credit_applied_total','')::numeric,0)
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
      if jsonb_array_length(v_rows)>0 then
        insert into public.purchase_invoices
        select * from jsonb_populate_recordset(null::public.purchase_invoices,v_rows);
      end if;
    elsif tbl='sales_invoices' then
      -- Customer-credit application did not exist in older v2 exports.
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'customer_credit_applied_total',
        coalesce(nullif(value->>'customer_credit_applied_total','')::numeric,0)
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
      if jsonb_array_length(v_rows)>0 then
        insert into public.sales_invoices
        select * from jsonb_populate_recordset(null::public.sales_invoices,v_rows);
      end if;
    elsif tbl='expenses' then
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'status',coalesce(nullif(value->>'status',''),'posted')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
      if jsonb_array_length(v_rows)>0 then
        insert into public.expenses
        select * from jsonb_populate_recordset(null::public.expenses,v_rows);
      end if;
    elsif tbl='treasury_transfers' then
      select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_transfer_id','') is null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.treasury_transfers
        select * from jsonb_populate_recordset(null::public.treasury_transfers,v_rows);
      end if;
      select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_transfer_id','') is not null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.treasury_transfers
        select * from jsonb_populate_recordset(null::public.treasury_transfers,v_rows);
      end if;
    elsif tbl='customer_credit_ledger' then
      select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_id','') is null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.customer_credit_ledger
        select * from jsonb_populate_recordset(null::public.customer_credit_ledger,v_rows);
      end if;
      select coalesce(jsonb_agg(value),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_id','') is not null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.customer_credit_ledger
        select * from jsonb_populate_recordset(null::public.customer_credit_ledger,v_rows);
      end if;
    elsif tbl='payments' then
      select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
        coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_payment_id','') is null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.payments
        select * from jsonb_populate_recordset(null::public.payments,v_rows);
      end if;
      select coalesce(jsonb_agg(value || jsonb_build_object('posted_at',
        coalesce(nullif(value->>'posted_at',''),value->>'created_at'))),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_payment_id','') is not null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.payments
        select * from jsonb_populate_recordset(null::public.payments,v_rows);
      end if;
    elsif tbl='sales_returns' then
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'status',coalesce(nullif(value->>'status',''),'posted'),
        'posted_at',coalesce(nullif(value->>'posted_at',''),value->>'created_at')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);
      if jsonb_array_length(v_rows)>0 then
        insert into public.sales_returns
        select * from jsonb_populate_recordset(null::public.sales_returns,v_rows);
      end if;
    elsif tbl='sales_return_items' then
      -- Recover a missing legacy unit_price from its originating sales item.
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'unit_price',
        coalesce(
          nullif(value->>'unit_price','')::numeric,
          (
            select round(
              nullif(si.value->>'line_total','')::numeric
              / nullif(nullif(si.value->>'quantity','')::numeric,0),
              2
            )
            from jsonb_array_elements(p_backup->'tables'->'sales_items') si(value)
            where si.value->>'id'=value->>'sales_item_id'
          )
        )
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value);

      if exists (
        select 1 from jsonb_array_elements(v_rows) restored(value)
        where nullif(restored.value->>'unit_price','') is null
      ) then
        raise exception 'لا يمكن استعادة بند مرتجع قديم دون سعر بند البيع الأصلي';
      end if;

      if jsonb_array_length(v_rows)>0 then
        insert into public.sales_return_items
        select * from jsonb_populate_recordset(null::public.sales_return_items,v_rows);
      end if;
    elsif tbl='stock_movements' then
      -- Preserve the already-exported final product average_cost and each movement's
      -- average_cost_before. The AFTER INSERT trigger would otherwise apply customer
      -- return cost changes a second time during backup restoration.
      if not exists (
        select 1 from pg_trigger t
        where t.tgrelid='public.stock_movements'::regclass
          and t.tgname='stock_movements_customer_return_average_cost'
          and not t.tgisinternal and t.tgenabled='O'
      ) then
        raise exception 'Customer-return average-cost trigger changed state; restore was stopped';
      end if;
      alter table public.stock_movements
        disable trigger stock_movements_customer_return_average_cost;

      select coalesce(jsonb_agg(value || jsonb_build_object(
        'posted_at',coalesce(nullif(value->>'posted_at',''),value->>'created_at'),
        'stock_bucket',coalesce(nullif(value->>'stock_bucket',''),'sellable')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_movement_id','') is null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.stock_movements
        select * from jsonb_populate_recordset(null::public.stock_movements,v_rows);
      end if;

      select coalesce(jsonb_agg(value || jsonb_build_object(
        'posted_at',coalesce(nullif(value->>'posted_at',''),value->>'created_at'),
        'stock_bucket',coalesce(nullif(value->>'stock_bucket',''),'sellable')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_movement_id','') is not null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.stock_movements
        select * from jsonb_populate_recordset(null::public.stock_movements,v_rows);
      end if;

      -- Re-enable before leaving this table. If any statement errors, PostgreSQL rolls
      -- back the trigger-state DDL together with the restore transaction.
      alter table public.stock_movements
        enable trigger stock_movements_customer_return_average_cost;
    elsif tbl='cash_transactions' then
      select coalesce(jsonb_agg(value || jsonb_build_object(
        'account_method',coalesce(nullif(value->>'account_method',''),'cash')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_transaction_id','') is null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.cash_transactions
        select * from jsonb_populate_recordset(null::public.cash_transactions,v_rows);
      end if;

      select coalesce(jsonb_agg(value || jsonb_build_object(
        'account_method',coalesce(nullif(value->>'account_method',''),'cash')
      )),'[]'::jsonb) into v_rows
      from jsonb_array_elements(p_backup->'tables'->tbl) as x(value)
      where nullif(value->>'reversal_of_transaction_id','') is not null;
      if jsonb_array_length(v_rows)>0 then
        insert into public.cash_transactions
        select * from jsonb_populate_recordset(null::public.cash_transactions,v_rows);
      end if;
    elsif jsonb_array_length(p_backup->'tables'->tbl)>0 then
      execute format(
        'insert into public.%I select * from jsonb_populate_recordset(null::public.%I,$1)',
        tbl,tbl
      ) using p_backup->'tables'->tbl;
    end if;
  end loop;

  return jsonb_build_object('restored',true,'business_id',p_business_id,
    'tables',to_jsonb(required_tables));
end;
$function$;

revoke all on function public.restore_business_backup(uuid,jsonb) from public, anon, authenticated;
grant execute on function public.restore_business_backup(uuid,jsonb) to authenticated, service_role;

commit;

-- Required tests before approval:
-- * restore a real v2 fixture and a v3 fixture into an empty disposable database.
-- * recover a missing legacy sales_return_items.unit_price from the matching sales_items row.
-- * verify legacy status/posted_at, stock_bucket, and account_method defaults.
-- * verify wrong business, unknown/null version, non-empty business, missing references, and missing images fail closed.
-- * verify transaction rollback leaves the target empty after any injected error.
-- * verify customer_return_good rows preserve exported products.average_cost and average_cost_before without reapplying the AFTER INSERT trigger.
-- Not executed on Test or Production.
