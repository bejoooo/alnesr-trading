-- DRAFT ONLY — Production unique/performance indexes and CHECK constraints.
-- Apply only AFTER the additive tables/columns stage and BEFORE helper triggers/RPCs.
-- Never run on current Test or Production without a separately approved execution plan.
-- No data is deleted or rewritten by this file. Unique-index creation will abort the transaction
-- if existing data violates a uniqueness rule.

begin;

-- 0) Required columns/tables must already exist.
do $$
declare missing text;
begin
  select string_agg(format('%I.%I',v.tbl,v.col),', ' order by v.tbl,v.col)
    into missing
  from (values
    ('cash_transactions','business_id'),('cash_transactions','purchase_return_id'),
    ('cash_transactions','sales_return_id'),('cash_transactions','payment_id'),
    ('cash_transactions','treasury_transfer_id'),('cash_transactions','reversal_of_transaction_id'),
    ('cash_transactions','transaction_code'),('cash_transactions','account_method'),('cash_transactions','transaction_date'),
    ('expenses','cash_transaction_id'),('expenses','expense_code'),('expenses','voided_by'),
    ('parties','party_code'),
    ('payments','business_id'),('payments','purchase_return_id'),('payments','sales_return_id'),
    ('payments','reversal_of_payment_id'),('payments','payment_code'),('payments','invoice_id'),('payments','posted_at'),
    ('sales_returns','business_id'),('sales_returns','sales_invoice_id'),('sales_returns','posted_at'),
    ('stock_movements','business_id'),('stock_movements','movement_code'),('stock_movements','reversal_of_movement_id'),
    ('stock_movements','product_id'),('stock_movements','stock_bucket'),('stock_movements','posted_at'),
    ('purchase_invoices','supplier_credit_applied_total'),
    ('sales_invoices','customer_credit_applied_total'),
    ('sales_return_items','unit_price')
  ) v(tbl,col)
  where to_regclass(format('public.%I',v.tbl)) is null
     or not exists(select 1 from information_schema.columns c
       where c.table_schema='public' and c.table_name=v.tbl and c.column_name=v.col);
  if missing is not null then
    raise exception 'Preflight failed: required index/check columns missing: %',missing;
  end if;
end $$;

-- 1) Duplicate preflight for every partial/functional unique business rule.
do $$
begin
  if exists(select 1 from public.cash_transactions
    where purchase_return_id is not null and reversal_of_transaction_id is null
    group by business_id,purchase_return_id having count(*)>1)
    then raise exception 'Duplicate original cash refund rows per purchase return'; end if;

  if exists(select 1 from public.cash_transactions
    where payment_id is not null group by payment_id having count(*)>1)
    then raise exception 'Duplicate cash ledger rows per payment'; end if;

  if exists(select 1 from public.cash_transactions
    where reversal_of_transaction_id is not null
    group by reversal_of_transaction_id having count(*)>1)
    then raise exception 'Multiple cash reversals reference the same original transaction'; end if;

  if exists(select 1 from public.cash_transactions
    where treasury_transfer_id is not null group by treasury_transfer_id having count(*)>1)
    then raise exception 'Multiple cash ledger rows reference the same treasury transfer'; end if;

  if exists(select 1 from public.expenses
    where cash_transaction_id is not null group by cash_transaction_id having count(*)>1)
    then raise exception 'Multiple expenses reference the same cash transaction'; end if;

  if exists(select 1 from public.payments
    where purchase_return_id is not null and reversal_of_payment_id is null
    group by business_id,purchase_return_id having count(*)>1)
    then raise exception 'Duplicate original payment rows per purchase return'; end if;

  if exists(select 1 from public.payments
    where reversal_of_payment_id is not null
    group by reversal_of_payment_id having count(*)>1)
    then raise exception 'Multiple payment reversals reference the same original payment'; end if;

  if exists(select 1 from public.stock_movements
    where reversal_of_movement_id is not null
    group by reversal_of_movement_id having count(*)>1)
    then raise exception 'Multiple stock reversals reference the same original movement'; end if;
  if exists(select 1 from public.cash_transactions
    where transaction_code is not null group by business_id,transaction_code having count(*)>1)
    then raise exception 'Duplicate cash transaction codes'; end if;
  if exists(select 1 from public.expenses
    where expense_code is not null group by business_id,expense_code having count(*)>1)
    then raise exception 'Duplicate expense codes'; end if;
  if exists(select 1 from public.parties
    where party_code is not null group by business_id,party_code having count(*)>1)
    then raise exception 'Duplicate party codes'; end if;
  if exists(select 1 from public.payments
    where payment_code is not null group by business_id,payment_code having count(*)>1)
    then raise exception 'Duplicate payment codes'; end if;
  if exists(select 1 from public.stock_movements
    where movement_code is not null group by business_id,movement_code having count(*)>1)
    then raise exception 'Duplicate stock movement codes'; end if;
end $$;

-- 2) Unique indexes: operation codes and one-to-one reversal/link protections.
create unique index if not exists cash_one_original_per_purchase_return
  on public.cash_transactions (business_id,purchase_return_id)
  where purchase_return_id is not null and reversal_of_transaction_id is null;
create unique index if not exists cash_transactions_one_per_payment
  on public.cash_transactions (payment_id) where payment_id is not null;
create unique index if not exists cash_transactions_one_reversal_per_original
  on public.cash_transactions (reversal_of_transaction_id) where reversal_of_transaction_id is not null;
create unique index if not exists cash_transactions_transaction_code_uq
  on public.cash_transactions (business_id,transaction_code);
create unique index if not exists cash_transactions_treasury_transfer_uidx
  on public.cash_transactions (treasury_transfer_id) where treasury_transfer_id is not null;
create unique index if not exists expenses_cash_transaction_unique
  on public.expenses (cash_transaction_id) where cash_transaction_id is not null;
create unique index if not exists expenses_expense_code_uq
  on public.expenses (business_id,expense_code);
create unique index if not exists parties_party_code_uq
  on public.parties (business_id,party_code);
create unique index if not exists payments_one_original_per_purchase_return
  on public.payments (business_id,purchase_return_id)
  where purchase_return_id is not null and reversal_of_payment_id is null;
create unique index if not exists payments_one_reversal_per_original
  on public.payments (reversal_of_payment_id) where reversal_of_payment_id is not null;
create unique index if not exists payments_payment_code_uq
  on public.payments (business_id,payment_code);
create unique index if not exists stock_movements_movement_code_uq
  on public.stock_movements (business_id,movement_code);
create unique index if not exists stock_movements_one_reversal_per_original
  on public.stock_movements (reversal_of_movement_id) where reversal_of_movement_id is not null;

-- 3) Non-unique indexes used by Preview's current reports and filtered lookups.
create index if not exists cash_business_sales_return_idx
  on public.cash_transactions (business_id,sales_return_id) where sales_return_id is not null;
create index if not exists cash_transactions_business_account_date_idx
  on public.cash_transactions (business_id,account_method,transaction_date desc,created_at desc);
create index if not exists expenses_voided_by_idx
  on public.expenses (voided_by) where voided_by is not null;
create index if not exists payments_business_invoice_posted_idx
  on public.payments (business_id,invoice_id,posted_at);
create index if not exists payments_business_sales_return_idx
  on public.payments (business_id,sales_return_id) where sales_return_id is not null;
create index if not exists sales_returns_business_invoice_posted_idx
  on public.sales_returns (business_id,sales_invoice_id,posted_at);
create index if not exists stock_movements_bucket_product_idx
  on public.stock_movements (business_id,product_id,stock_bucket);
create index if not exists stock_movements_business_product_posted_idx
  on public.stock_movements (business_id,product_id,posted_at);

-- 4) CHECK constraints missing from Production but present in the tested schema.
do $$
begin
  if not exists(select 1 from pg_constraint where conrelid='public.payments'::regclass and conname='payments_method_supported_check') then
    alter table public.payments add constraint payments_method_supported_check
      check (lower(btrim(method)) = any (array['cash','bank_transfer','instapay','mobile_wallet','other']::text[])) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.payments'::regclass and conname='payments_party_account_type_check') then
    alter table public.payments add constraint payments_party_account_type_check
      check (party_account_type is null or party_account_type = any (array['customer','supplier']::text[])) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.purchase_invoices'::regclass and conname='purchase_invoices_supplier_credit_applied_total_check') then
    alter table public.purchase_invoices add constraint purchase_invoices_supplier_credit_applied_total_check
      check (supplier_credit_applied_total >= 0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.sales_invoices'::regclass and conname='sales_invoices_customer_credit_applied_total_check') then
    alter table public.sales_invoices add constraint sales_invoices_customer_credit_applied_total_check
      check (customer_credit_applied_total >= 0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.sales_return_items'::regclass and conname='sales_return_items_unit_price_nonnegative') then
    alter table public.sales_return_items add constraint sales_return_items_unit_price_nonnegative
      check (unit_price >= 0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.sales_returns'::regclass and conname='sales_returns_invoice_due_reduced_total_check') then
    alter table public.sales_returns add constraint sales_returns_invoice_due_reduced_total_check
      check (invoice_due_reduced_total is null or invoice_due_reduced_total >= 0) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.sales_returns'::regclass and conname='sales_returns_status_check') then
    alter table public.sales_returns add constraint sales_returns_status_check
      check (status = any (array['posted','void']::text[])) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.stock_movements'::regclass and conname='stock_movements_stock_bucket_check') then
    alter table public.stock_movements add constraint stock_movements_stock_bucket_check
      check (stock_bucket = any (array['sellable','damaged']::text[])) not valid;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.expenses'::regclass and conname='expenses_status_check') then
    alter table public.expenses add constraint expenses_status_check
      check (status = any (array['posted','void']::text[])) not valid;
  end if;

  -- Production's legacy movement_type check is narrower than the tested Preview schema.
  -- Replace only that named constraint, preserving all rows and the other table constraints.
  if exists(select 1 from pg_constraint where conrelid='public.stock_movements'::regclass
      and conname='stock_movements_movement_type_check'
      and (pg_get_constraintdef(oid) not like '%purchase_return%'
        or pg_get_constraintdef(oid) not like '%customer_return_damaged%'
        or pg_get_constraintdef(oid) not like '%condition_transfer_in%'
        or pg_get_constraintdef(oid) not like '%condition_transfer_out%')) then
    alter table public.stock_movements drop constraint stock_movements_movement_type_check;
  end if;
  if not exists(select 1 from pg_constraint where conrelid='public.stock_movements'::regclass and conname='stock_movements_movement_type_check') then
    alter table public.stock_movements add constraint stock_movements_movement_type_check
      check (movement_type = any (array[
        'purchase','sale','customer_return_good','customer_return_damaged','damage','loss',
        'adjustment_in','adjustment_out','opening','purchase_return','condition_transfer_in','condition_transfer_out'
      ]::text[])) not valid;
  end if;
end $$;

-- 5) Validate after all objects are in place. Validation is read-only over existing rows.
alter table public.payments validate constraint payments_method_supported_check;
alter table public.payments validate constraint payments_party_account_type_check;
alter table public.purchase_invoices validate constraint purchase_invoices_supplier_credit_applied_total_check;
alter table public.sales_invoices validate constraint sales_invoices_customer_credit_applied_total_check;
alter table public.sales_return_items validate constraint sales_return_items_unit_price_nonnegative;
alter table public.sales_returns validate constraint sales_returns_invoice_due_reduced_total_check;
alter table public.sales_returns validate constraint sales_returns_status_check;
alter table public.stock_movements validate constraint stock_movements_stock_bucket_check;
alter table public.expenses validate constraint expenses_status_check;
alter table public.stock_movements validate constraint stock_movements_movement_type_check;

commit;
