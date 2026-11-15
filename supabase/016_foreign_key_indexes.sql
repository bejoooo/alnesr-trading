-- Al Nesr Trading — supporting indexes for foreign keys
-- Add indexes to child-side foreign-key columns to improve joins and parent
-- update/delete checks as the business data grows. Existing leading composite
-- indexes are reused where they already support a shorter business_id FK.

create index if not exists audit_log_actor_id_idx on public.audit_log (actor_id);
create index if not exists business_members_user_id_idx on public.business_members (user_id);
create index if not exists businesses_created_by_idx on public.businesses (created_by);

create index if not exists cash_transactions_business_party_idx on public.cash_transactions (business_id, party_id);
create index if not exists cash_transactions_created_by_idx on public.cash_transactions (created_by);
create index if not exists cash_transactions_party_id_idx on public.cash_transactions (party_id);

create index if not exists expenses_business_id_idx on public.expenses (business_id);
create index if not exists expenses_created_by_idx on public.expenses (created_by);

create index if not exists payments_business_party_idx on public.payments (business_id, party_id);
create index if not exists payments_created_by_idx on public.payments (created_by);
create index if not exists payments_party_id_idx on public.payments (party_id);

create index if not exists purchase_invoices_business_supplier_idx on public.purchase_invoices (business_id, supplier_id);
create index if not exists purchase_invoices_created_by_idx on public.purchase_invoices (created_by);
create index if not exists purchase_invoices_supplier_id_idx on public.purchase_invoices (supplier_id);

create index if not exists purchase_items_business_product_idx on public.purchase_items (business_id, product_id);
create index if not exists purchase_items_invoice_id_idx on public.purchase_items (invoice_id);
create index if not exists purchase_items_product_id_idx on public.purchase_items (product_id);

create index if not exists sales_invoices_business_customer_idx on public.sales_invoices (business_id, customer_id);
create index if not exists sales_invoices_created_by_idx on public.sales_invoices (created_by);
create index if not exists sales_invoices_customer_id_idx on public.sales_invoices (customer_id);

create index if not exists sales_items_business_product_idx on public.sales_items (business_id, product_id);
create index if not exists sales_items_invoice_id_idx on public.sales_items (invoice_id);
create index if not exists sales_items_product_id_idx on public.sales_items (product_id);

create index if not exists sales_return_items_business_product_idx on public.sales_return_items (business_id, product_id);
create index if not exists sales_return_items_business_return_idx on public.sales_return_items (business_id, return_id);
create index if not exists sales_return_items_business_sales_item_idx on public.sales_return_items (business_id, sales_item_id);
create index if not exists sales_return_items_product_id_idx on public.sales_return_items (product_id);
create index if not exists sales_return_items_return_id_idx on public.sales_return_items (return_id);
create index if not exists sales_return_items_sales_item_id_idx on public.sales_return_items (sales_item_id);

create index if not exists sales_returns_business_customer_idx on public.sales_returns (business_id, customer_id);
create index if not exists sales_returns_created_by_idx on public.sales_returns (created_by);
create index if not exists sales_returns_customer_id_idx on public.sales_returns (customer_id);
create index if not exists sales_returns_sales_invoice_id_idx on public.sales_returns (sales_invoice_id);

create index if not exists stock_movements_created_by_idx on public.stock_movements (created_by);
create index if not exists stock_movements_product_id_idx on public.stock_movements (product_id);
