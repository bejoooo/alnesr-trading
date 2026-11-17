-- Keep the original unique cash link index; avoid a duplicate equivalent index.
drop index if exists public.expenses_cash_transaction_id_unique;

-- Support lookups by the user who cancelled an expense.
create index if not exists expenses_voided_by_idx
 on public.expenses(voided_by) where voided_by is not null;
