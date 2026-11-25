-- Read-only Production baseline preflight. No DDL/DML.
select 'businesses' table_name,count(*) row_count from public.businesses
union all select 'business_members',count(*) from public.business_members
union all select 'products',count(*) from public.products
union all select 'parties',count(*) from public.parties
union all select 'purchase_invoices',count(*) from public.purchase_invoices
union all select 'purchase_items',count(*) from public.purchase_items
union all select 'sales_invoices',count(*) from public.sales_invoices
union all select 'sales_items',count(*) from public.sales_items
union all select 'payments',count(*) from public.payments
union all select 'stock_movements',count(*) from public.stock_movements
union all select 'sales_returns',count(*) from public.sales_returns
union all select 'sales_return_items',count(*) from public.sales_return_items
union all select 'expenses',count(*) from public.expenses
union all select 'cash_transactions',count(*) from public.cash_transactions
union all select 'business_settings',count(*) from public.business_settings
union all select 'audit_log',count(*) from public.audit_log
order by table_name;

select c.relname table_name,c.relrowsecurity rls_enabled,c.relforcerowsecurity force_rls
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind='r'
order by c.relname;

select 'product-images' bucket_id,public,file_size_limit,allowed_mime_types,
       (select count(*) from storage.objects o where o.bucket_id=b.id) object_count
from storage.buckets b where id='product-images';

select count(*) migration_history_rows from supabase_migrations.schema_migrations;
