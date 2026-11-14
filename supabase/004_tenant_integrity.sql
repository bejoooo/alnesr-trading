-- Al Nesr Trading — tenant-safe relational constraints
-- Apply after 003_atomic_business_operations.sql.
-- These composite foreign keys prevent records from linking to another business,
-- even if a client bypasses the intended UI flow.

alter table public.products
  add constraint products_business_id_id_uk unique (business_id,id);
alter table public.parties
  add constraint parties_business_id_id_uk unique (business_id,id);
alter table public.purchase_invoices
  add constraint purchase_invoices_business_id_id_uk unique (business_id,id);
alter table public.sales_invoices
  add constraint sales_invoices_business_id_id_uk unique (business_id,id);
alter table public.sales_items
  add constraint sales_items_business_id_id_uk unique (business_id,id);
alter table public.sales_returns
  add constraint sales_returns_business_id_id_uk unique (business_id,id);

alter table public.purchase_invoices
  add constraint purchase_invoice_supplier_same_business_fk
  foreign key (business_id,supplier_id)
  references public.parties (business_id,id);

alter table public.purchase_items
  add constraint purchase_item_invoice_same_business_fk
  foreign key (business_id,invoice_id)
  references public.purchase_invoices (business_id,id) on delete cascade,
  add constraint purchase_item_product_same_business_fk
  foreign key (business_id,product_id)
  references public.products (business_id,id);

alter table public.sales_invoices
  add constraint sales_invoice_customer_same_business_fk
  foreign key (business_id,customer_id)
  references public.parties (business_id,id);

alter table public.sales_items
  add constraint sales_item_invoice_same_business_fk
  foreign key (business_id,invoice_id)
  references public.sales_invoices (business_id,id) on delete cascade,
  add constraint sales_item_product_same_business_fk
  foreign key (business_id,product_id)
  references public.products (business_id,id);

alter table public.stock_movements
  add constraint stock_movement_product_same_business_fk
  foreign key (business_id,product_id)
  references public.products (business_id,id);

alter table public.sales_returns
  add constraint sales_return_invoice_same_business_fk
  foreign key (business_id,sales_invoice_id)
  references public.sales_invoices (business_id,id),
  add constraint sales_return_customer_same_business_fk
  foreign key (business_id,customer_id)
  references public.parties (business_id,id);

alter table public.sales_return_items
  add constraint return_item_return_same_business_fk
  foreign key (business_id,return_id)
  references public.sales_returns (business_id,id) on delete cascade,
  add constraint return_item_sales_item_same_business_fk
  foreign key (business_id,sales_item_id)
  references public.sales_items (business_id,id),
  add constraint return_item_product_same_business_fk
  foreign key (business_id,product_id)
  references public.products (business_id,id);

alter table public.payments
  add constraint payment_party_same_business_fk
  foreign key (business_id,party_id)
  references public.parties (business_id,id);

alter table public.cash_transactions
  add constraint cash_party_same_business_fk
  foreign key (business_id,party_id)
  references public.parties (business_id,id);
