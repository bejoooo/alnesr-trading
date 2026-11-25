-- DRAFT ONLY — Al Nesr Trading production structural hardening
-- Target: production AFTER the additive table/column stage has been applied.
-- DO NOT RUN against Test or Production yet.
-- This file intentionally does not create tables/columns, policies, triggers, views, or RPCs.
-- It does not drop existing single-column FKs; those are retained to preserve their current delete behavior.
-- Review the full upgrade plan and run the read-only preflight before any execution.

begin;

-- Stop explicitly if the prerequisite additive schema stage is incomplete.
do $
declare missing text;
begin
  select string_agg(format('%I.%I', v.tbl, v.col), ', ' order by v.tbl, v.col)
    into missing
  from (values
    ('payments','business_id'),('payments','reversal_of_payment_id'),
    ('cash_transactions','business_id'),('cash_transactions','payment_id'),
    ('cash_transactions','treasury_transfer_id'),('cash_transactions','reversal_of_transaction_id'),
    ('expenses','business_id'),('expenses','cash_transaction_id'),
    ('stock_movements','business_id'),('stock_movements','reversal_of_movement_id'),
    ('purchase_returns','business_id'),('purchase_returns','purchase_invoice_id'),('purchase_returns','supplier_id'),
    ('purchase_return_items','business_id'),('purchase_return_items','return_id'),
    ('purchase_return_items','purchase_item_id'),('purchase_return_items','product_id'),
    ('customer_credit_ledger','business_id'),('customer_credit_ledger','customer_id'),
    ('customer_credit_ledger','source_return_id'),('customer_credit_ledger','invoice_id'),
    ('customer_credit_ledger','payment_id'),('customer_credit_ledger','reversal_of_id'),
    ('purchase_invoice_cost_snapshots','business_id'),('purchase_invoice_cost_snapshots','invoice_id'),
    ('purchase_invoice_cost_snapshots','product_id'),
    ('stock_adjustment_cost_snapshots','business_id'),('stock_adjustment_cost_snapshots','movement_id'),
    ('stock_adjustment_cost_snapshots','product_id'),
    ('purchase_items','business_id'),('purchase_items','id'),
    ('purchase_invoices','business_id'),('purchase_invoices','id'),
    ('parties','business_id'),('parties','id'),
    ('products','business_id'),('products','id'),
    ('sales_returns','business_id'),('sales_returns','id'),
    ('sales_invoices','business_id'),('sales_invoices','id'),
    ('treasury_transfers','business_id'),('treasury_transfers','id')
  ) as v(tbl,col)
  where to_regclass(format('public.%I', v.tbl)) is null
     or not exists (
       select 1 from information_schema.columns ic
       where ic.table_schema='public' and ic.table_name=v.tbl and ic.column_name=v.col
     );

  if missing is not null then
    raise exception 'Preflight failed: prerequisite tables/columns missing: %', missing;
  end if;
end $;

-- 1) Candidate composite-key targets not currently unique on (business_id, id).
-- The single-column PKs remain in place.
create unique index if not exists payments_business_id_id_uk
  on public.payments (business_id, id);

create unique index if not exists cash_transactions_business_id_id_uk
  on public.cash_transactions (business_id, id);

create unique index if not exists stock_movements_business_id_id_uk
  on public.stock_movements (business_id, id);

create unique index if not exists purchase_items_business_id_id_uk
  on public.purchase_items (business_id, id);

-- 2) Refuse to proceed if an existing reference crosses business boundaries.
do $$
begin
  if exists (
    select 1 from public.payments child
    join public.payments parent on parent.id = child.reversal_of_payment_id
    where child.reversal_of_payment_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: payments reversal crosses business boundary'; end if;

  if exists (
    select 1 from public.cash_transactions child
    join public.payments parent on parent.id = child.payment_id
    where child.payment_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: cash_transactions.payment_id crosses business boundary'; end if;

  if exists (
    select 1 from public.cash_transactions child
    join public.treasury_transfers parent on parent.id = child.treasury_transfer_id
    where child.treasury_transfer_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: cash_transactions.treasury_transfer_id crosses business boundary'; end if;

  if exists (
    select 1 from public.cash_transactions child
    join public.cash_transactions parent on parent.id = child.reversal_of_transaction_id
    where child.reversal_of_transaction_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: cash transaction reversal crosses business boundary'; end if;

  if exists (
    select 1 from public.expenses child
    join public.cash_transactions parent on parent.id = child.cash_transaction_id
    where child.cash_transaction_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: expense cash link crosses business boundary'; end if;

  if exists (
    select 1 from public.stock_movements child
    join public.stock_movements parent on parent.id = child.reversal_of_movement_id
    where child.reversal_of_movement_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: stock movement reversal crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_returns child
    join public.purchase_invoices parent on parent.id = child.purchase_invoice_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase return invoice crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_returns child
    join public.parties parent on parent.id = child.supplier_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase return supplier crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_return_items child
    join public.purchase_returns parent on parent.id = child.return_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase return item parent crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_return_items child
    join public.purchase_items parent on parent.id = child.purchase_item_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase return item source item crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_return_items child
    join public.products parent on parent.id = child.product_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase return item product crosses business boundary'; end if;

  if exists (
    select 1 from public.customer_credit_ledger child
    join public.parties parent on parent.id = child.customer_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: customer credit customer crosses business boundary'; end if;

  if exists (
    select 1 from public.customer_credit_ledger child
    join public.sales_returns parent on parent.id = child.source_return_id
    where child.source_return_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: customer credit return crosses business boundary'; end if;

  if exists (
    select 1 from public.customer_credit_ledger child
    join public.sales_invoices parent on parent.id = child.invoice_id
    where child.invoice_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: customer credit invoice crosses business boundary'; end if;

  if exists (
    select 1 from public.customer_credit_ledger child
    join public.payments parent on parent.id = child.payment_id
    where child.payment_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: customer credit payment crosses business boundary'; end if;

  if exists (
    select 1 from public.customer_credit_ledger child
    join public.customer_credit_ledger parent on parent.id = child.reversal_of_id
    where child.reversal_of_id is not null
      and child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: customer credit reversal crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_invoice_cost_snapshots child
    join public.purchase_invoices parent on parent.id = child.invoice_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase cost snapshot invoice crosses business boundary'; end if;

  if exists (
    select 1 from public.purchase_invoice_cost_snapshots child
    join public.products parent on parent.id = child.product_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: purchase cost snapshot product crosses business boundary'; end if;

  if exists (
    select 1 from public.stock_adjustment_cost_snapshots child
    join public.stock_movements parent on parent.id = child.movement_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: stock cost snapshot movement crosses business boundary'; end if;

  if exists (
    select 1 from public.stock_adjustment_cost_snapshots child
    join public.products parent on parent.id = child.product_id
    where child.business_id <> parent.business_id
  ) then raise exception 'Preflight failed: stock cost snapshot product crosses business boundary'; end if;
end $$;

-- 3) Add missing composite FKs as NOT VALID first.
-- MATCH SIMPLE remains PostgreSQL's default: nullable reference columns are permitted.
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.payments'::regclass and conname='payments_reversal_same_business_fk') then
    alter table public.payments add constraint payments_reversal_same_business_fk
      foreign key (business_id, reversal_of_payment_id)
      references public.payments (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.cash_transactions'::regclass and conname='cash_payment_same_business_fk') then
    alter table public.cash_transactions add constraint cash_payment_same_business_fk
      foreign key (business_id, payment_id)
      references public.payments (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.cash_transactions'::regclass and conname='cash_transfer_same_business_fk') then
    alter table public.cash_transactions add constraint cash_transfer_same_business_fk
      foreign key (business_id, treasury_transfer_id)
      references public.treasury_transfers (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.cash_transactions'::regclass and conname='cash_reversal_same_business_fk') then
    alter table public.cash_transactions add constraint cash_reversal_same_business_fk
      foreign key (business_id, reversal_of_transaction_id)
      references public.cash_transactions (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.expenses'::regclass and conname='expense_cash_same_business_fk') then
    alter table public.expenses add constraint expense_cash_same_business_fk
      foreign key (business_id, cash_transaction_id)
      references public.cash_transactions (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.stock_movements'::regclass and conname='stock_reversal_same_business_fk') then
    alter table public.stock_movements add constraint stock_reversal_same_business_fk
      foreign key (business_id, reversal_of_movement_id)
      references public.stock_movements (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_returns'::regclass and conname='purchase_return_invoice_same_business_fk') then
    alter table public.purchase_returns add constraint purchase_return_invoice_same_business_fk
      foreign key (business_id, purchase_invoice_id)
      references public.purchase_invoices (business_id, id) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_returns'::regclass and conname='purchase_return_supplier_same_business_fk') then
    alter table public.purchase_returns add constraint purchase_return_supplier_same_business_fk
      foreign key (business_id, supplier_id)
      references public.parties (business_id, id) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_return_items'::regclass and conname='purchase_return_item_parent_same_business_fk') then
    alter table public.purchase_return_items add constraint purchase_return_item_parent_same_business_fk
      foreign key (business_id, return_id)
      references public.purchase_returns (business_id, id) on delete cascade not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_return_items'::regclass and conname='purchase_return_item_source_same_business_fk') then
    alter table public.purchase_return_items add constraint purchase_return_item_source_same_business_fk
      foreign key (business_id, purchase_item_id)
      references public.purchase_items (business_id, id) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_return_items'::regclass and conname='purchase_return_item_product_same_business_fk') then
    alter table public.purchase_return_items add constraint purchase_return_item_product_same_business_fk
      foreign key (business_id, product_id)
      references public.products (business_id, id) not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.customer_credit_ledger'::regclass and conname='customer_credit_party_same_business_fk') then
    alter table public.customer_credit_ledger add constraint customer_credit_party_same_business_fk
      foreign key (business_id, customer_id)
      references public.parties (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.customer_credit_ledger'::regclass and conname='customer_credit_return_same_business_fk') then
    alter table public.customer_credit_ledger add constraint customer_credit_return_same_business_fk
      foreign key (business_id, source_return_id)
      references public.sales_returns (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.customer_credit_ledger'::regclass and conname='customer_credit_invoice_same_business_fk') then
    alter table public.customer_credit_ledger add constraint customer_credit_invoice_same_business_fk
      foreign key (business_id, invoice_id)
      references public.sales_invoices (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.customer_credit_ledger'::regclass and conname='customer_credit_payment_same_business_fk') then
    alter table public.customer_credit_ledger add constraint customer_credit_payment_same_business_fk
      foreign key (business_id, payment_id)
      references public.payments (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.customer_credit_ledger'::regclass and conname='customer_credit_reversal_same_business_fk') then
    alter table public.customer_credit_ledger add constraint customer_credit_reversal_same_business_fk
      foreign key (business_id, reversal_of_id)
      references public.customer_credit_ledger (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_invoice_cost_snapshots'::regclass and conname='purchase_cost_snapshot_invoice_same_business_fk') then
    alter table public.purchase_invoice_cost_snapshots add constraint purchase_cost_snapshot_invoice_same_business_fk
      foreign key (business_id, invoice_id)
      references public.purchase_invoices (business_id, id) on delete cascade not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.purchase_invoice_cost_snapshots'::regclass and conname='purchase_cost_snapshot_product_same_business_fk') then
    alter table public.purchase_invoice_cost_snapshots add constraint purchase_cost_snapshot_product_same_business_fk
      foreign key (business_id, product_id)
      references public.products (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.stock_adjustment_cost_snapshots'::regclass and conname='stock_cost_snapshot_movement_same_business_fk') then
    alter table public.stock_adjustment_cost_snapshots add constraint stock_cost_snapshot_movement_same_business_fk
      foreign key (business_id, movement_id)
      references public.stock_movements (business_id, id) on delete restrict not valid;
  end if;

  if not exists (select 1 from pg_constraint where conrelid='public.stock_adjustment_cost_snapshots'::regclass and conname='stock_cost_snapshot_product_same_business_fk') then
    alter table public.stock_adjustment_cost_snapshots add constraint stock_cost_snapshot_product_same_business_fk
      foreign key (business_id, product_id)
      references public.products (business_id, id) on delete restrict not valid;
  end if;
end $$;

-- 4) Validate all constraints only after the preflight and index creation succeed.
alter table public.payments validate constraint payments_reversal_same_business_fk;
alter table public.cash_transactions validate constraint cash_payment_same_business_fk;
alter table public.cash_transactions validate constraint cash_transfer_same_business_fk;
alter table public.cash_transactions validate constraint cash_reversal_same_business_fk;
alter table public.expenses validate constraint expense_cash_same_business_fk;
alter table public.stock_movements validate constraint stock_reversal_same_business_fk;
alter table public.purchase_returns validate constraint purchase_return_invoice_same_business_fk;
alter table public.purchase_returns validate constraint purchase_return_supplier_same_business_fk;
alter table public.purchase_return_items validate constraint purchase_return_item_parent_same_business_fk;
alter table public.purchase_return_items validate constraint purchase_return_item_source_same_business_fk;
alter table public.purchase_return_items validate constraint purchase_return_item_product_same_business_fk;
alter table public.customer_credit_ledger validate constraint customer_credit_party_same_business_fk;
alter table public.customer_credit_ledger validate constraint customer_credit_return_same_business_fk;
alter table public.customer_credit_ledger validate constraint customer_credit_invoice_same_business_fk;
alter table public.customer_credit_ledger validate constraint customer_credit_payment_same_business_fk;
alter table public.customer_credit_ledger validate constraint customer_credit_reversal_same_business_fk;
alter table public.purchase_invoice_cost_snapshots validate constraint purchase_cost_snapshot_invoice_same_business_fk;
alter table public.purchase_invoice_cost_snapshots validate constraint purchase_cost_snapshot_product_same_business_fk;
alter table public.stock_adjustment_cost_snapshots validate constraint stock_cost_snapshot_movement_same_business_fk;
alter table public.stock_adjustment_cost_snapshots validate constraint stock_cost_snapshot_product_same_business_fk;

commit;
