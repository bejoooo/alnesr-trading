-- DRAFT ONLY — additive missing columns for the production schema
-- Exact types/defaults were read from the current Test schema.
-- Code columns and sales_return_items.unit_price are deliberately nullable at this stage.
-- Do not set them NOT NULL until triggers/backfill are safely implemented and verified.
-- No data is updated or deleted by this file.

begin;

alter table public.businesses
  add column if not exists tagline text;

alter table public.parties
  add column if not exists is_active boolean not null default true,
  add column if not exists party_code text;

alter table public.purchase_invoices
  add column if not exists supplier_credit_applied_total numeric(14,2) not null default 0;

alter table public.sales_invoices
  add column if not exists customer_credit_applied_total numeric(14,2) not null default 0;

alter table public.payments
  add column if not exists sales_return_id uuid,
  add column if not exists reversal_of_payment_id uuid,
  add column if not exists posted_at timestamptz not null default clock_timestamp(),
  add column if not exists party_account_type text,
  add column if not exists payment_code text,
  add column if not exists purchase_return_id uuid;

alter table public.stock_movements
  add column if not exists reversal_of_movement_id uuid,
  add column if not exists posted_at timestamptz not null default clock_timestamp(),
  add column if not exists movement_code text,
  add column if not exists stock_bucket text not null default 'sellable',
  add column if not exists average_cost_before numeric(14,4);

alter table public.sales_returns
  add column if not exists status text not null default 'posted',
  add column if not exists posted_at timestamptz not null default clock_timestamp(),
  add column if not exists invoice_due_reduced_total numeric(14,2);

alter table public.sales_return_items
  add column if not exists unit_price numeric(14,2);

alter table public.expenses
  add column if not exists cash_transaction_id uuid,
  add column if not exists status text not null default 'posted',
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid,
  add column if not exists expense_code text;

alter table public.cash_transactions
  add column if not exists reversal_of_transaction_id uuid,
  add column if not exists sales_return_id uuid,
  add column if not exists payment_id uuid,
  add column if not exists treasury_transfer_id uuid,
  add column if not exists transaction_code text,
  add column if not exists account_method text not null default 'cash',
  add column if not exists purchase_return_id uuid;

commit;

-- Follow-up requirements (not executed here):
-- 1) Inspect and reconcile existing constraints before adding any new FK/check.
-- 2) Add code-generation function dependencies and BEFORE INSERT triggers.
-- 3) Backfill code columns with deterministic, uniqueness-checked values; then SET NOT NULL.
-- 4) Backfill sales_return_items.unit_price from the original sales_items record; then SET NOT NULL.
-- 5) Add and validate the appropriate FK/check/index definitions after data preflight.
