-- DRAFT ONLY — additive production schema stage
-- Source: inspected Test schema (7 operational tables, 32 missing columns).
-- Not executable as a complete go-live migration:
-- 1) code columns remain nullable until code-generation RPCs/triggers are installed and safely backfilled.
-- 2) sales_return_items.unit_price remains nullable until backfilled from the originating sales item.
-- 3) cross-business composite FKs are in PRODUCTION_STRUCTURAL_FK_DRAFT.sql and must run after this file.
-- 4) dependent RPCs, views, triggers, RLS grants and functional tests are a later stage.
-- No data is copied, deleted, reset, or rewritten by this draft.

begin;

-- Fail closed if a target table exists already in Production unexpectedly.
do $$
declare existing_tables text;
begin
  select string_agg(t, ', ' order by t) into existing_tables
  from unnest(array[
    'purchase_invoice_cost_snapshots','stock_adjustment_cost_snapshots',
    'treasury_transfers','operation_counters','purchase_returns',
    'purchase_return_items','customer_credit_ledger'
  ]) as t
  where to_regclass(format('public.%I', t)) is not null;

  if existing_tables is not null then
    raise exception 'Preflight failed: expected new tables already exist; inspect before proceeding: %', existing_tables;
  end if;
end $$;

-- A) Seven operational tables reconstructed from the Test catalog.

create table public.operation_counters (
  business_id uuid not null,
  operation_type text not null,
  last_number bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint operation_counters_pkey primary key (business_id, operation_type),
  constraint operation_counters_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint operation_counters_last_number_check check (last_number >= 0)
);

create table public.purchase_returns (
  id uuid not null default gen_random_uuid(),
  business_id uuid not null,
  return_no text not null,
  purchase_invoice_id uuid not null,
  supplier_id uuid not null,
  return_date date not null default current_date,
  total numeric(14,2) not null default 0,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  posted_at timestamptz not null default clock_timestamp(),
  status text not null default 'posted',
  credit_generated_total numeric(14,2) not null default 0,
  invoice_due_reduced_total numeric(14,2),
  constraint purchase_returns_pkey primary key (id),
  constraint purchase_returns_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint purchase_returns_created_by_fkey
    foreign key (created_by) references auth.users(id),
  constraint purchase_returns_total_check check (total >= 0),
  constraint purchase_returns_credit_generated_total_check check (credit_generated_total >= 0),
  constraint purchase_returns_status_check check (status = any (array['posted'::text,'void'::text])),
  constraint purchase_returns_business_id_id_key unique (business_id,id),
  constraint purchase_returns_business_id_return_no_key unique (business_id,return_no)
);

create table public.purchase_return_items (
  id uuid not null default gen_random_uuid(),
  business_id uuid not null,
  return_id uuid not null,
  purchase_item_id uuid not null,
  product_id uuid not null,
  quantity numeric(14,3) not null,
  condition text not null,
  unit_cost numeric(14,2) not null,
  line_total numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint purchase_return_items_pkey primary key (id),
  constraint purchase_return_items_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint purchase_return_items_return_id_fkey
    foreign key (return_id) references public.purchase_returns(id) on delete cascade,
  constraint purchase_return_items_purchase_item_id_fkey
    foreign key (purchase_item_id) references public.purchase_items(id),
  constraint purchase_return_items_product_id_fkey
    foreign key (product_id) references public.products(id),
  constraint purchase_return_items_condition_check check (condition = any (array['good'::text,'damaged'::text])),
  constraint purchase_return_items_quantity_check check (quantity > 0),
  constraint purchase_return_items_unit_cost_check check (unit_cost >= 0),
  constraint purchase_return_items_line_total_check check (line_total >= 0)
);

create table public.customer_credit_ledger (
  id uuid not null default gen_random_uuid(),
  business_id uuid not null,
  customer_id uuid not null,
  source_return_id uuid,
  invoice_id uuid,
  payment_id uuid,
  event_type text not null,
  amount numeric(14,2) not null,
  reversal_of_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint customer_credit_ledger_pkey primary key (id),
  constraint customer_credit_ledger_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint customer_credit_ledger_created_by_fkey
    foreign key (created_by) references auth.users(id),
  constraint customer_credit_ledger_customer_id_fkey
    foreign key (customer_id) references public.parties(id) on delete restrict,
  constraint customer_credit_ledger_source_return_id_fkey
    foreign key (source_return_id) references public.sales_returns(id) on delete restrict,
  constraint customer_credit_ledger_invoice_id_fkey
    foreign key (invoice_id) references public.sales_invoices(id) on delete restrict,
  constraint customer_credit_ledger_payment_id_fkey
    foreign key (payment_id) references public.payments(id) on delete restrict,
  constraint customer_credit_ledger_reversal_of_id_fkey
    foreign key (reversal_of_id) references public.customer_credit_ledger(id) on delete restrict,
  constraint customer_credit_ledger_amount_check check (amount <> 0),
  constraint customer_credit_ledger_event_type_check
    check (event_type = any (array['return_credit'::text,'invoice_application'::text,'payout'::text,'reversal'::text])),
  constraint customer_credit_business_id_id_uk unique (business_id,id),
  constraint customer_credit_reversal_unique unique (reversal_of_id)
);

create table public.purchase_invoice_cost_snapshots (
  business_id uuid not null,
  invoice_id uuid not null,
  product_id uuid not null,
  average_cost_before numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint purchase_invoice_cost_snapshots_pkey primary key (invoice_id,product_id),
  constraint purchase_invoice_cost_snapshots_invoice_id_fkey
    foreign key (invoice_id) references public.purchase_invoices(id) on delete cascade,
  constraint purchase_invoice_cost_snapshots_product_id_fkey
    foreign key (product_id) references public.products(id) on delete restrict
);

create table public.stock_adjustment_cost_snapshots (
  business_id uuid not null,
  movement_id uuid not null,
  product_id uuid not null,
  average_cost_before numeric(14,2) not null,
  created_at timestamptz not null default now(),
  constraint stock_adjustment_cost_snapshots_pkey primary key (business_id,movement_id),
  constraint stock_adjustment_cost_snapshots_movement_id_fkey
    foreign key (movement_id) references public.stock_movements(id) on delete restrict,
  constraint stock_adjustment_cost_snapshots_product_id_fkey
    foreign key (product_id) references public.products(id) on delete restrict
);

create table public.treasury_transfers (
  id uuid not null default gen_random_uuid(),
  business_id uuid not null,
  transfer_date date not null default current_date,
  source_method text not null,
  destination_method text not null,
  amount numeric(14,2) not null,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now(),
  transfer_code text not null,
  reversal_of_transfer_id uuid,
  constraint treasury_transfers_pkey primary key (id),
  constraint treasury_transfers_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint treasury_transfers_created_by_fkey
    foreign key (created_by) references auth.users(id),
  constraint treasury_transfer_business_id_id_unique unique (business_id,id),
  constraint treasury_transfers_amount_check check (amount > 0),
  constraint treasury_transfer_distinct_methods check (source_method <> destination_method),
  constraint treasury_transfers_source_method_check
    check (source_method = any (array['cash'::text,'instapay'::text,'bank_transfer'::text,'mobile_wallet'::text,'other'::text])),
  constraint treasury_transfers_destination_method_check
    check (destination_method = any (array['cash'::text,'instapay'::text,'bank_transfer'::text,'mobile_wallet'::text,'other'::text])),
  constraint treasury_transfers_no_self_reversal
    check (reversal_of_transfer_id is null or reversal_of_transfer_id <> id),
  constraint treasury_transfers_reversal_same_business_fkey
    foreign key (business_id,reversal_of_transfer_id)
    references public.treasury_transfers(business_id,id) on delete restrict
);

-- B) Indexes copied from the verified Test catalog.
create index customer_credit_customer_idx on public.customer_credit_ledger (business_id,customer_id,created_at);
create index customer_credit_source_idx on public.customer_credit_ledger (business_id,source_return_id);
create index customer_credit_ledger_created_by_idx on public.customer_credit_ledger (created_by);
create index customer_credit_ledger_customer_id_idx on public.customer_credit_ledger (customer_id);
create index customer_credit_ledger_invoice_id_idx on public.customer_credit_ledger (invoice_id);
create index customer_credit_ledger_payment_id_idx on public.customer_credit_ledger (payment_id);
create index customer_credit_ledger_source_return_id_idx on public.customer_credit_ledger (source_return_id);

create index purchase_returns_invoice_idx on public.purchase_returns (business_id,purchase_invoice_id,status);
create index purchase_returns_supplier_idx on public.purchase_returns (business_id,supplier_id,status);
create index purchase_returns_purchase_invoice_id_idx on public.purchase_returns (purchase_invoice_id);
create index purchase_returns_supplier_id_idx on public.purchase_returns (supplier_id);

create index purchase_return_items_return_idx on public.purchase_return_items (business_id,return_id);
create index purchase_return_items_purchase_item_idx on public.purchase_return_items (business_id,purchase_item_id);
create index purchase_return_items_return_id_idx on public.purchase_return_items (return_id);
create index purchase_return_items_purchase_item_id_idx on public.purchase_return_items (purchase_item_id);
create index purchase_return_items_product_id_idx on public.purchase_return_items (product_id);

create index purchase_invoice_cost_snapshots_product_id_idx on public.purchase_invoice_cost_snapshots (product_id);
create index stock_adjustment_cost_snapshots_movement_id_idx on public.stock_adjustment_cost_snapshots (movement_id);
create index stock_adjustment_cost_snapshots_product_id_idx on public.stock_adjustment_cost_snapshots (product_id);

create index treasury_transfers_business_date_idx on public.treasury_transfers (business_id,transfer_date desc,created_at desc);
create index treasury_transfers_created_by_idx on public.treasury_transfers (created_by);
create unique index treasury_transfers_one_reversal_per_transfer
  on public.treasury_transfers (business_id,reversal_of_transfer_id)
  where reversal_of_transfer_id is not null;
create unique index treasury_transfers_transfer_code_uq
  on public.treasury_transfers (business_id,transfer_code);

-- C) RLS and API access. No anon grants are copied from Test.
alter table public.operation_counters enable row level security;
alter table public.purchase_returns enable row level security;
alter table public.purchase_return_items enable row level security;
alter table public.customer_credit_ledger enable row level security;
alter table public.purchase_invoice_cost_snapshots enable row level security;
alter table public.stock_adjustment_cost_snapshots enable row level security;
alter table public.treasury_transfers enable row level security;

revoke all on table public.operation_counters, public.purchase_returns,
  public.purchase_return_items, public.customer_credit_ledger,
  public.purchase_invoice_cost_snapshots, public.stock_adjustment_cost_snapshots,
  public.treasury_transfers from anon, authenticated;

grant all on table public.operation_counters, public.purchase_returns,
  public.purchase_return_items, public.customer_credit_ledger,
  public.purchase_invoice_cost_snapshots, public.stock_adjustment_cost_snapshots,
  public.treasury_transfers to service_role;

grant select on table public.purchase_returns, public.purchase_return_items,
  public.customer_credit_ledger, public.purchase_invoice_cost_snapshots,
  public.stock_adjustment_cost_snapshots, public.treasury_transfers to authenticated;

create policy purchase_returns_read on public.purchase_returns
  for select to authenticated
  using (public.has_business_permission(business_id,'purchases.view'));

create policy purchase_return_items_read on public.purchase_return_items
  for select to authenticated
  using (public.has_business_permission(business_id,'purchases.view'));

create policy customer_credit_ledger_read on public.customer_credit_ledger
  for select to authenticated
  using (public.has_business_permission(business_id,'sales.view')
      or public.has_business_permission(business_id,'parties.view'));

create policy owner_read_purchase_cost_snapshots on public.purchase_invoice_cost_snapshots
  for select to authenticated
  using (public.has_business_role(business_id,array['owner']::text[]));

create policy owner_read_stock_adjustment_cost_snapshots on public.stock_adjustment_cost_snapshots
  for select to authenticated
  using (public.has_business_role(business_id,array['owner']::text[]));

create policy treasury_transfers_read on public.treasury_transfers
  for select to authenticated
  using (public.has_business_permission(business_id,'treasury_transfer.view'));

-- operation_counters intentionally has no API grants and no RLS policies;
-- only trusted SECURITY DEFINER code may access it.

commit;

-- Caution for the next staged migration:
-- add the 32 missing columns using the exact types/defaults from NEW_OPERATIONAL_TABLES_SPEC_AR.md.
-- Keep party_code, payment_code, transaction_code, movement_code, expense_code nullable initially.
-- Install and test next_operation_code + assign_business_record_code and their BEFORE INSERT triggers.
-- Backfill legacy code columns using a controlled, uniqueness-checked procedure, then SET NOT NULL.
-- Add sales_return_items.unit_price nullable first; backfill from its originating sales item price;
-- only then add NOT NULL. Do not fabricate prices or codes.
