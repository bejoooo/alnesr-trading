-- Al Nesr Trading — owner-only empty-business restore
-- Backups are exported by the client as JSON and can only restore into the same,
-- currently empty business. This intentionally refuses destructive overwrite.
create or replace function public.restore_business_backup(p_business_id uuid, p_backup jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  tbl text;
  row_count bigint;
  required_tables text[] := array[
    'products','parties','purchase_invoices','purchase_items','sales_invoices',
    'sales_items','payments','stock_movements','sales_returns','sales_return_items',
    'expenses','cash_transactions','business_settings'
  ];
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول لاستعادة النسخة الاحتياطية';
  end if;
  if not exists (
    select 1 from public.business_members
    where business_id=p_business_id and user_id=auth.uid()
      and active=true and role='owner'
  ) then
    raise exception 'استعادة النسخة الاحتياطية متاحة لمالك النشاط فقط';
  end if;
  if jsonb_typeof(p_backup) <> 'object'
     or p_backup->>'format_version' <> 'alnesr-business-backup-v1'
     or p_backup->>'business_id' <> p_business_id::text
     or jsonb_typeof(p_backup->'tables') <> 'object' then
    raise exception 'ملف النسخة الاحتياطية غير صالح أو تابع لنشاط آخر';
  end if;

  foreach tbl in array required_tables loop
    if jsonb_typeof(p_backup->'tables'->tbl) <> 'array' then
      raise exception 'ملف النسخة الاحتياطية ناقص بيانات الجدول %', tbl;
    end if;
    if exists (
      select 1 from jsonb_array_elements(p_backup->'tables'->tbl) as row_data
      where row_data->>'business_id' is distinct from p_business_id::text
    ) then
      raise exception 'النسخة تحتوي سجلات لا تخص هذا النشاط في الجدول %', tbl;
    end if;
    execute format('select count(*) from public.%I where business_id=$1',tbl)
      into row_count using p_business_id;
    if row_count > 0 then
      raise exception 'لا يمكن الاستعادة فوق بيانات موجودة. الجدول % يحتوي بالفعل على سجلات.', tbl;
    end if;
  end loop;

  -- Parent tables first; any error rolls the whole restore back.
  foreach tbl in array required_tables loop
    if jsonb_array_length(p_backup->'tables'->tbl) > 0 then
      execute format(
        'insert into public.%I select * from jsonb_populate_recordset(null::public.%I,$1)',
        tbl,tbl
      ) using p_backup->'tables'->tbl;
    end if;
  end loop;

  return jsonb_build_object('restored',true,'business_id',p_business_id,
    'tables',to_jsonb(required_tables));
end;
$$;

revoke all on function public.restore_business_backup(uuid,jsonb) from public;
grant execute on function public.restore_business_backup(uuid,jsonb) to authenticated;
