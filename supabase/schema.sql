-- Al Nesr Trading — Supabase foundation
-- Apply once in the Supabase SQL Editor on a NEW project.
-- All monetary values are EGP. Stock is ledger-based; catalog creation never creates stock.

create extension if not exists pgcrypto;

create table if not exists public.businesses (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text,
  address text,
  currency text not null default 'EGP' check (currency = 'EGP'),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.business_members (
  business_id uuid not null references public.businesses(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'staff' check (role in ('owner','admin','manager','cashier','viewer')),
  permissions jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (business_id, user_id)
);

create or replace function public.is_business_member(bid uuid)
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.business_members m
    where m.business_id = bid and m.user_id = auth.uid() and m.active = true
  );
$$;

create or replace function public.has_business_role(bid uuid, allowed_roles text[])
returns boolean language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.business_members m
    where m.business_id = bid and m.user_id = auth.uid()
      and m.active = true and m.role = any(allowed_roles)
  );
$$;

create or replace function public.add_business_creator_as_owner()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  insert into public.business_members (business_id, user_id, role)
  values (new.id, new.created_by, 'owner')
  on conflict (business_id, user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists businesses_add_creator on public.businesses;
create trigger businesses_add_creator after insert on public.businesses
for each row execute function public.add_business_creator_as_owner();

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text,
  name text not null,
  category text,
  unit text not null default 'قطعة',
  average_cost numeric(14,2) not null default 0 check (average_cost >= 0),
  wholesale_price numeric(14,2) not null default 0 check (wholesale_price >= 0),
  retail_price numeric(14,2) not null default 0 check (retail_price >= 0),
  minimum_stock numeric(14,3) not null default 0 check (minimum_stock >= 0),
  warranty text,
  warranty_provider text,
  specs text,
  image_path text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, code)
);

create table if not exists public.parties (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  kind text not null check (kind in ('customer','supplier','both')),
  name text not null,
  company text,
  phone text,
  address text,
  customer_type text check (customer_type in ('wholesale','retail') or customer_type is null),
  notes text,
  opening_balance numeric(14,2) not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.purchase_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_no text not null,
  supplier_id uuid references public.parties(id),
  supplier_name_snapshot text,
  invoice_date date not null default current_date,
  subtotal numeric(14,2) not null default 0,
  supplier_discount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, invoice_no),
  check (supplier_discount >= 0 and total >= 0)
);

create table if not exists public.purchase_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.purchase_invoices(id) on delete cascade,
  product_id uuid not null references public.products(id),
  product_name_snapshot text not null,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  allocated_discount numeric(14,2) not null default 0,
  net_line_total numeric(14,2) not null check (net_line_total >= 0),
  unit_landed_cost numeric(14,4) not null check (unit_landed_cost >= 0)
);

create table if not exists public.sales_invoices (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_no text not null,
  customer_id uuid references public.parties(id),
  customer_name_snapshot text not null default 'عميل نقدي',
  invoice_date date not null default current_date,
  subtotal numeric(14,2) not null default 0,
  discount numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  paid_total numeric(14,2) not null default 0,
  due_total numeric(14,2) not null default 0,
  status text not null default 'posted' check (status in ('draft','posted','partially_returned','returned','void')),
  business_name_snapshot text,
  business_phone_snapshot text,
  business_address_snapshot text,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, invoice_no),
  check (discount >= 0 and total >= 0 and paid_total >= 0 and due_total >= 0)
);

create table if not exists public.sales_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  invoice_id uuid not null references public.sales_invoices(id) on delete cascade,
  product_id uuid not null references public.products(id),
  product_name_snapshot text not null,
  product_code_snapshot text,
  warranty_snapshot text,
  warranty_provider_snapshot text,
  quantity numeric(14,3) not null check (quantity > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  line_discount numeric(14,2) not null default 0,
  unit_cost_snapshot numeric(14,4) not null check (unit_cost_snapshot >= 0),
  line_total numeric(14,2) not null check (line_total >= 0),
  returned_quantity numeric(14,3) not null default 0 check (returned_quantity >= 0)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  party_id uuid references public.parties(id),
  invoice_id uuid,
  direction text not null check (direction in ('in','out')),
  amount numeric(14,2) not null check (amount > 0),
  payment_date date not null default current_date,
  method text not null default 'cash',
  reference text,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  product_id uuid not null references public.products(id),
  movement_date date not null default current_date,
  movement_type text not null check (movement_type in ('purchase','sale','customer_return_good','damage','loss','adjustment_in','adjustment_out','opening')),
  quantity_delta numeric(14,3) not null check (quantity_delta <> 0),
  unit_cost numeric(14,4) not null default 0,
  source_type text,
  source_id uuid,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.sales_returns (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  return_no text not null,
  sales_invoice_id uuid not null references public.sales_invoices(id),
  customer_id uuid references public.parties(id),
  return_date date not null default current_date,
  refund_total numeric(14,2) not null default 0,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (business_id, return_no)
);

create table if not exists public.sales_return_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  return_id uuid not null references public.sales_returns(id) on delete cascade,
  sales_item_id uuid not null references public.sales_items(id),
  product_id uuid not null references public.products(id),
  quantity numeric(14,3) not null check (quantity > 0),
  condition text not null check (condition in ('good','damaged')),
  refund_amount numeric(14,2) not null default 0 check (refund_amount >= 0)
);

create table if not exists public.expenses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null,
  amount numeric(14,2) not null check (amount > 0),
  expense_date date not null default current_date,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.cash_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  transaction_date date not null default current_date,
  direction text not null check (direction in ('in','out')),
  transaction_type text not null check (transaction_type in ('opening_balance','deposit','sale_payment','purchase_payment','customer_refund','expense','other')),
  amount numeric(14,2) not null check (amount > 0),
  party_id uuid references public.parties(id),
  invoice_id uuid,
  reason text,
  notes text,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.business_settings (
  business_id uuid primary key references public.businesses(id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.audit_log (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Row-level security: users can only access records belonging to a business they belong to.
alter table public.businesses enable row level security;
alter table public.business_members enable row level security;

do $$
declare t text;
begin
  foreach t in array array['products','parties','purchase_invoices','purchase_items','sales_invoices','sales_items','payments','stock_movements','sales_returns','sales_return_items','expenses','cash_transactions','business_settings','audit_log']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_access', t);
    execute format('create policy %I on public.%I for all using (public.is_business_member(business_id)) with check (public.is_business_member(business_id))', t || '_member_access', t);
  end loop;
end $$;

drop policy if exists businesses_member_read on public.businesses;
create policy businesses_member_read on public.businesses for select using (public.is_business_member(id));
drop policy if exists businesses_creator_insert on public.businesses;
create policy businesses_creator_insert on public.businesses for insert with check (created_by = auth.uid());
drop policy if exists businesses_admin_update on public.businesses;
create policy businesses_admin_update on public.businesses for update using (public.has_business_role(id, array['owner','admin'])) with check (public.has_business_role(id, array['owner','admin']));

drop policy if exists members_read on public.business_members;
create policy members_read on public.business_members for select using (public.is_business_member(business_id));
drop policy if exists members_admin_manage on public.business_members;
create policy members_admin_manage on public.business_members for all using (public.has_business_role(business_id, array['owner','admin'])) with check (public.has_business_role(business_id, array['owner','admin']));

create index if not exists products_business_name_idx on public.products (business_id, name);
create index if not exists parties_business_kind_idx on public.parties (business_id, kind);
create index if not exists purchase_invoices_business_date_idx on public.purchase_invoices (business_id, invoice_date);
create index if not exists sales_invoices_business_date_idx on public.sales_invoices (business_id, invoice_date);
create index if not exists stock_movements_product_date_idx on public.stock_movements (business_id, product_id, movement_date);
create index if not exists cash_transactions_business_date_idx on public.cash_transactions (business_id, transaction_date);
create index if not exists audit_log_business_created_idx on public.audit_log (business_id, created_at desc);
