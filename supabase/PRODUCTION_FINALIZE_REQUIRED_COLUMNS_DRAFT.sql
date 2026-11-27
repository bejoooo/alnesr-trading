-- DRAFT ONLY — finalize required fields after code-assignment triggers exist.
-- Apply AFTER PRODUCTION_HELPER_FUNCTIONS_TRIGGERS_DRAFT.sql and its hardening patch.
-- Never run on Test/Production without explicit approval and a verified backup.
-- The only data backfill is sales_return_items.unit_price from its exact source sales_items row.
-- No synthetic codes or prices are generated.

begin;

do $$
declare
  missing_triggers text;
  missing_columns text;
begin
  select string_agg(format('%I.%I',v.tbl,v.col), ', ' order by v.tbl,v.col)
    into missing_columns
  from (values
    ('parties','party_code'),('payments','payment_code'),
    ('cash_transactions','transaction_code'),('stock_movements','movement_code'),
    ('expenses','expense_code'),('treasury_transfers','transfer_code'),
    ('sales_return_items','unit_price'),('sales_return_items','sales_item_id'),
    ('sales_return_items','business_id'),('sales_items','id'),
    ('sales_items','business_id'),('sales_items','unit_price')
  ) v(tbl,col)
  where to_regclass(format('public.%I',v.tbl)) is null
     or not exists(select 1 from information_schema.columns c
       where c.table_schema='public' and c.table_name=v.tbl and c.column_name=v.col);
  if missing_columns is not null then
    raise exception 'Required columns are missing for finalization: %',missing_columns;
  end if;

  select string_agg(v.trigger_name, ', ' order by v.trigger_name)
    into missing_triggers
  from (values
    ('cash_transactions_assign_code','cash_transactions'),
    ('expenses_assign_code','expenses'),
    ('parties_assign_code','parties'),
    ('payments_assign_code','payments'),
    ('stock_movements_assign_code','stock_movements'),
    ('treasury_transfers_assign_code','treasury_transfers')
  ) v(trigger_name,table_name)
  where not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname=v.table_name
      and not t.tgisinternal and t.tgenabled in ('O','A')
      and t.tgname=v.trigger_name
  );

  if missing_triggers is not null then
    raise exception 'Required code-assignment triggers are missing: %',missing_triggers;
  end if;

  -- Production was confirmed to have no operational rows at the baseline.
  -- If rows were added before this stage, stop rather than inventing identifiers.
  if exists(select 1 from public.parties where party_code is null)
    or exists(select 1 from public.payments where payment_code is null)
    or exists(select 1 from public.cash_transactions where transaction_code is null)
    or exists(select 1 from public.stock_movements where movement_code is null)
    or exists(select 1 from public.expenses where expense_code is null)
    or exists(select 1 from public.treasury_transfers where transfer_code is null) then
    raise exception 'Null operation codes exist. Resolve them with a reviewed, uniqueness-checked backfill before setting NOT NULL.';
  end if;
end $$;

-- Preserve the actual sold unit price from the originating sales item.
-- A missing source row is an error; do not substitute product list price or current price.
update public.sales_return_items sri
set unit_price=si.unit_price
from public.sales_items si
where sri.unit_price is null
  and si.id=sri.sales_item_id
  and si.business_id=sri.business_id;

do $$
begin
  if exists(select 1 from public.sales_return_items where unit_price is null) then
    raise exception 'Some sales return items have no source sales item price; no guessed value will be used.';
  end if;
end $$;

alter table public.parties alter column party_code set not null;
alter table public.payments alter column payment_code set not null;
alter table public.cash_transactions alter column transaction_code set not null;
alter table public.stock_movements alter column movement_code set not null;
alter table public.expenses alter column expense_code set not null;
alter table public.treasury_transfers alter column transfer_code set not null;
alter table public.sales_return_items alter column unit_price set not null;

commit;
