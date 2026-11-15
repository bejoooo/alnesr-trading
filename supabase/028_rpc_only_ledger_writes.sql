-- 028: Ledger and audit tables are RPC/trigger managed; deny direct API writes.
revoke insert, update, delete on table
  public.purchase_invoices,
  public.purchase_items,
  public.sales_invoices,
  public.sales_items,
  public.sales_returns,
  public.sales_return_items,
  public.payments,
  public.cash_transactions,
  public.stock_movements,
  public.expenses,
  public.audit_log,
  public.business_settings
from anon, authenticated;

do $assert$
begin
  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema='public'
      and table_name in (
        'purchase_invoices','purchase_items','sales_invoices','sales_items',
        'sales_returns','sales_return_items','payments','cash_transactions',
        'stock_movements','expenses','audit_log','business_settings'
      )
      and grantee in ('anon','authenticated')
      and privilege_type in ('INSERT','UPDATE','DELETE')
  ) then
    raise exception 'Migration 028 assertion failed: direct ledger writes remain granted';
  end if;
end;
$assert$;