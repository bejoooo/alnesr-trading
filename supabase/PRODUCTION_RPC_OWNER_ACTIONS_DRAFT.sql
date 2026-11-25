-- DRAFT ONLY — owner management, archive, reversal, and void RPC batch
-- Exact function definitions extracted from the current Test schema.
-- Destructive owner actions are preserved only with their existing guards and audit records.
-- reset_business_data and restore_business_backup are intentionally excluded from this batch.

begin;
set local search_path = pg_catalog, public;

do $preflight$
declare v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name) into v_missing
  from (values
    ('public.audit_log'),
    ('public.business_members'),
    ('public.cash_balances'),
    ('public.cash_transactions'),
    ('public.customer_credit_ledger'),
    ('public.expenses'),
    ('public.parties'),
    ('public.payments'),
    ('public.products'),
    ('public.purchase_invoice_cost_snapshots'),
    ('public.purchase_invoices'),
    ('public.purchase_items'),
    ('public.purchase_return_items'),
    ('public.purchase_returns'),
    ('public.sales_invoices'),
    ('public.sales_items'),
    ('public.sales_return_items'),
    ('public.sales_returns'),
    ('public.stock_movements'),
    ('public.treasury_transfers')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing base tables for owner RPC batch: %',array_to_string(v_missing,', ');
  end if;

  if exists (
    select 1
    from (values
      ('business_members','role'),
      ('business_members','active'),
      ('parties','is_active'),
      ('products','is_active'),
      ('sales_invoices','status'),
      ('purchase_invoices','status'),
      ('sales_returns','status'),
      ('payments','reversal_of_payment_id'),
      ('payments','posted_at'),
      ('cash_transactions','reversal_of_transaction_id'),
      ('cash_transactions','account_method'),
      ('stock_movements','reversal_of_movement_id'),
      ('stock_movements','posted_at'),
      ('expenses','status'),
      ('expenses','voided_at'),
      ('expenses','voided_by'),
      ('expenses','cash_transaction_id'),
      ('purchase_returns','status'),
      ('customer_credit_ledger','reversal_of_id'),
      ('treasury_transfers','reversal_of_transfer_id')
    ) as required(table_name,column_name)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name=required.table_name
        and c.column_name=required.column_name
    )
  ) then
    raise exception 'Missing required columns for owner RPC batch';
  end if;
end
$preflight$;

-- add_business_member_by_email(uuid,text,text)
CREATE OR REPLACE FUNCTION public.add_business_member_by_email(p_business_id uuid, p_email text, p_role text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target_user_id uuid; normalized_email text := lower(btrim(coalesce(p_email,'')));
begin
 if auth.uid() is null or not exists(select 1 from public.business_members m where m.business_id=p_business_id and m.user_id=auth.uid() and m.role='owner' and m.active=true) then
  raise exception 'OWNER_REQUIRED';
 end if;
 if normalized_email='' or p_role not in ('manager','cashier','viewer') then raise exception 'INVALID_MEMBER_INPUT'; end if;
 select u.id into target_user_id from auth.users u where lower(u.email)=normalized_email and u.email_confirmed_at is not null limit 1;
 if target_user_id is null then raise exception 'USER_NOT_FOUND_OR_UNCONFIRMED'; end if;
 insert into public.business_members(business_id,user_id,role,permissions,active) values(p_business_id,target_user_id,p_role,'{}'::jsonb,true)
 on conflict(business_id,user_id) do nothing;
 if not found then raise exception 'MEMBER_ALREADY_EXISTS'; end if;
 return target_user_id;
end;
$function$;

revoke all on function public.add_business_member_by_email(uuid,text,text) from public, anon, authenticated;
grant execute on function public.add_business_member_by_email(uuid,text,text) to authenticated, service_role;

-- list_business_members(uuid)
CREATE OR REPLACE FUNCTION public.list_business_members(p_business_id uuid)
 RETURNS TABLE(user_id uuid, email text, role text, permissions jsonb, active boolean, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is null or not exists(select 1 from public.business_members m where m.business_id=p_business_id and m.user_id=auth.uid() and m.role='owner' and m.active=true) then
  raise exception 'OWNER_REQUIRED';
 end if;
 return query select m.user_id,u.email::text,m.role,m.permissions,m.active,m.created_at
 from public.business_members m join auth.users u on u.id=m.user_id
 where m.business_id=p_business_id
 order by case when m.role='owner' then 0 else 1 end,lower(coalesce(u.email,''));
end;
$function$;

revoke all on function public.list_business_members(uuid) from public, anon, authenticated;
grant execute on function public.list_business_members(uuid) to authenticated, service_role;

-- owner_remove_cash_opening_balance(uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_cash_opening_balance(p_business_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_tx record;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id
  and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can remove opening cash balance'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_tx from public.cash_transactions
 where business_id=p_business_id and transaction_type='opening_balance' for update;
 if not found then return 'no_opening_balance'; end if;
 if (select count(*) from public.cash_transactions where business_id=p_business_id)<>1 then
  raise exception 'Opening cash balance cannot be removed after any other cash movement exists';
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'remove_opening_balance','cash_transaction',v_tx.id,
 jsonb_build_object('amount',v_tx.amount,'date',v_tx.transaction_date));
 delete from public.cash_transactions where id=v_tx.id and business_id=p_business_id;
 return 'removed';
end;
$function$;

revoke all on function public.owner_remove_cash_opening_balance(uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_cash_opening_balance(uuid) to authenticated, service_role;

-- owner_remove_cash_transaction(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_cash_transaction(p_business_id uuid, p_transaction_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_tx record; v_balance numeric(14,2); v_reversal_id uuid;
begin
  if auth.uid() is null or not exists(select 1 from public.business_members where business_id=p_business_id and user_id=auth.uid() and role='owner' and active) then raise exception 'Only the active business owner can reverse cash transactions'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  select * into v_tx from public.cash_transactions where id=p_transaction_id and business_id=p_business_id for update;
  if not found then raise exception 'Cash transaction not found'; end if;
  if v_tx.reversal_of_transaction_id is not null then raise exception 'A reversal entry cannot itself be reversed here'; end if;
  if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_tx.id) then raise exception 'This cash movement has already been reversed'; end if;
  if v_tx.invoice_id is not null or v_tx.party_id is not null or v_tx.sales_return_id is not null or v_tx.treasury_transfer_id is not null or exists(select 1 from public.expenses e where e.cash_transaction_id=v_tx.id) or v_tx.transaction_type not in ('deposit','other') then raise exception 'This cash movement is linked to an invoice, expense, refund, or opening balance and cannot be removed here'; end if;
  if v_tx.account_method='cash' then
    select coalesce(balance,0) into v_balance from public.cash_balances where business_id=p_business_id; v_balance:=coalesce(v_balance,0);
  else
    select coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end) from public.payments p where p.business_id=p_business_id and lower(p.method)=v_tx.account_method),0)
      +coalesce((select sum(case when t.destination_method=v_tx.account_method then t.amount when t.source_method=v_tx.account_method then -t.amount else 0 end) from public.treasury_transfers t where t.business_id=p_business_id),0)
      +coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end) from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_tx.account_method) and c.payment_id is null and c.treasury_transfer_id is null),0)
    into v_balance;
  end if;
  if v_tx.direction='in' and coalesce(v_balance,0)<v_tx.amount then raise exception 'Treasury balance is insufficient to reverse this deposit'; end if;
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,reversal_of_transaction_id,account_method)
  values(p_business_id,current_date,case when v_tx.direction='in' then 'out' else 'in' end,'other',v_tx.amount,'عكس حركة خزنة: '||coalesce(v_tx.reason,'بدون بيان'),'عكس الحركة الأصلية رقم '||p_transaction_id,auth.uid(),v_tx.id,v_tx.account_method) returning id into v_reversal_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'remove_reversed','cash_transaction',p_transaction_id,jsonb_build_object('amount',v_tx.amount,'original_direction',v_tx.direction,'account_method',v_tx.account_method,'reversal_id',v_reversal_id));
  return 'reversed';
end; $function$;

revoke all on function public.owner_remove_cash_transaction(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_cash_transaction(uuid,uuid) to authenticated, service_role;

-- owner_remove_expense(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_expense(p_business_id uuid, p_expense_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_exp record;
 v_cash record;
 v_balance numeric(14,2);
 v_reversal_id uuid;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
 ) then
  raise exception 'Only the active business owner can remove expenses';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_exp from public.expenses
 where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'Expense not found'; end if;
 if v_exp.status='void' then raise exception 'Expense has already been cancelled'; end if;
 if v_exp.cash_transaction_id is null then
  raise exception 'This older expense has no verified cash link and cannot be safely removed';
 end if;
 select * into v_cash from public.cash_transactions
 where id=v_exp.cash_transaction_id and business_id=p_business_id for update;
 if not found or v_cash.transaction_type<>'expense' or v_cash.direction<>'out'
    or v_cash.amount<>v_exp.amount
    or v_cash.transaction_date<>v_exp.expense_date
    or v_cash.reason is distinct from v_exp.name
    or v_cash.invoice_id is not null or v_cash.party_id is not null
    or v_cash.sales_return_id is not null
    or v_cash.reversal_of_transaction_id is not null then
  raise exception 'The linked cash movement does not match this expense; no changes were made';
 end if;
 if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_cash.id) then
  raise exception 'This expense cash movement has already been reversed';
 end if;

 if v_cash.account_method='cash' then
   select coalesce(balance,0) into v_balance
   from public.cash_balances where business_id=p_business_id;
   v_balance:=coalesce(v_balance,0);
 else
   select
     coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
       from public.payments p where p.business_id=p_business_id and lower(p.method)=v_cash.account_method),0)
     + coalesce((select sum(case when t.destination_method=v_cash.account_method then t.amount
                                 when t.source_method=v_cash.account_method then -t.amount else 0 end)
       from public.treasury_transfers t where t.business_id=p_business_id),0)
     + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
       from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_cash.account_method) and c.payment_id is null and c.treasury_transfer_id is null),0)
   into v_balance;
 end if;

 insert into public.cash_transactions(
  business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,
  reversal_of_transaction_id,account_method
 ) values(
  p_business_id,current_date,'in','deposit',v_exp.amount,
  'عكس إلغاء مصروف: '||v_exp.name,
  'عكس حركة المصروف رقم '||coalesce(v_cash.transaction_code,p_expense_id::text),
  auth.uid(),v_cash.id,v_cash.account_method
 ) returning id into v_reversal_id;

 update public.expenses
 set status='void',voided_at=clock_timestamp(),voided_by=auth.uid()
 where id=p_expense_id and business_id=p_business_id and status='posted';
 if not found then raise exception 'Expense was changed before cancellation'; end if;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void_reversed','expense',p_expense_id,
  jsonb_build_object('amount',v_exp.amount,'method',v_cash.account_method,
                     'cash_transaction_id',v_cash.id,'reversal_id',v_reversal_id));
 return 'voided_reversed';
end;
$function$;

revoke all on function public.owner_remove_expense(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_expense(uuid,uuid) to authenticated, service_role;

-- owner_remove_party(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_party(p_business_id uuid, p_party_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_used boolean; v_result text;
begin
 if auth.uid() is null or not exists(select 1 from public.business_members where business_id=p_business_id and user_id=auth.uid() and role='owner' and active) then
   raise exception 'Only the active business owner can remove customers or suppliers';
 end if;
 perform 1 from public.parties where id=p_party_id and business_id=p_business_id for update;
 if not found then raise exception 'Customer or supplier not found'; end if;
 select (opening_balance<>0)
   or exists(select 1 from public.sales_invoices where business_id=p_business_id and customer_id=p_party_id)
   or exists(select 1 from public.purchase_invoices where business_id=p_business_id and supplier_id=p_party_id)
   or exists(select 1 from public.payments where business_id=p_business_id and party_id=p_party_id)
   or exists(select 1 from public.cash_transactions where business_id=p_business_id and party_id=p_party_id)
   or exists(select 1 from public.sales_returns where business_id=p_business_id and customer_id=p_party_id)
 into v_used from public.parties where id=p_party_id and business_id=p_business_id;
 if v_used then update public.parties set is_active=false where id=p_party_id and business_id=p_business_id; v_result:='archived';
 else delete from public.parties where id=p_party_id and business_id=p_business_id; v_result:='deleted'; end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),v_result,'party',p_party_id,jsonb_build_object('had_history',v_used));
 return v_result;
end;
$function$;

revoke all on function public.owner_remove_party(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_party(uuid,uuid) to authenticated, service_role;

-- owner_remove_party_opening_balance(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_party_opening_balance(p_business_id uuid, p_party_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_party record;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id
  and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can remove party opening balance'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_party from public.parties
 where id=p_party_id and business_id=p_business_id for update;
 if not found then raise exception 'Party not found'; end if;
 if exists(select 1 from public.sales_invoices where business_id=p_business_id and customer_id=p_party_id)
  or exists(select 1 from public.purchase_invoices where business_id=p_business_id and supplier_id=p_party_id)
  or exists(select 1 from public.payments where business_id=p_business_id and party_id=p_party_id)
  or exists(select 1 from public.sales_returns where business_id=p_business_id and customer_id=p_party_id)
  or exists(select 1 from public.cash_transactions where business_id=p_business_id and party_id=p_party_id) then
  raise exception 'Party opening balance cannot be removed after account activity exists';
 end if;
 update public.parties set opening_balance=0,opening_balance_side='receivable'
 where id=p_party_id and business_id=p_business_id;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'remove_opening_balance','party',p_party_id,
 jsonb_build_object('previous_amount',v_party.opening_balance,'previous_side',v_party.opening_balance_side));
 return 'removed';
end;
$function$;

revoke all on function public.owner_remove_party_opening_balance(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_party_opening_balance(uuid,uuid) to authenticated, service_role;

-- owner_remove_product(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_product(p_business_id uuid, p_product_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_used boolean; v_result text;
begin
 if auth.uid() is null or not exists(select 1 from public.business_members where business_id=p_business_id and user_id=auth.uid() and role='owner' and active) then
   raise exception 'Only the active business owner can remove products';
 end if;
 perform 1 from public.products where id=p_product_id and business_id=p_business_id for update;
 if not found then raise exception 'Product not found'; end if;
 select exists(
   select 1 from public.stock_movements where business_id=p_business_id and product_id=p_product_id
   union all select 1 from public.sales_items where business_id=p_business_id and product_id=p_product_id
   union all select 1 from public.purchase_items where business_id=p_business_id and product_id=p_product_id
   union all select 1 from public.sales_return_items where business_id=p_business_id and product_id=p_product_id
 ) into v_used;
 if v_used then update public.products set is_active=false,updated_at=now() where id=p_product_id; v_result:='archived';
 else delete from public.products where id=p_product_id and business_id=p_business_id; v_result:='deleted'; end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),v_result,'product',p_product_id,jsonb_build_object('had_history',v_used));
 return v_result;
end;
$function$;

revoke all on function public.owner_remove_product(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_product(uuid,uuid) to authenticated, service_role;

-- update_business_member(uuid,uuid,text,boolean,jsonb)
CREATE OR REPLACE FUNCTION public.update_business_member(p_business_id uuid, p_user_id uuid, p_role text, p_active boolean, p_permissions jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare target_role text;
begin
  if auth.uid() is null or not exists (
    select 1 from public.business_members m
    where m.business_id=p_business_id and m.user_id=auth.uid()
      and m.role='owner' and m.active=true
  ) then raise exception 'OWNER_REQUIRED'; end if;

  if p_role not in ('manager','cashier','viewer') or p_active is null
     or jsonb_typeof(p_permissions) <> 'object' then
    raise exception 'INVALID_MEMBER_INPUT';
  end if;

  if exists (
    select 1 from jsonb_each(p_permissions) e
    where e.key <> all (array[
      'products.view','products.create','products.edit',
      'parties.view','parties.create','parties.edit',
      'purchases.view','purchases.create','purchases.edit',
      'sales.view','sales.create','sales.edit',
      'payments.view','payments.create','payments.record',
      'inventory.view','inventory.create',
      'expenses.view','expenses.create','expenses.edit',
      'cash.view','cash.create','cash.deposit','cash.withdraw',
      'treasury_transfer.view','treasury_transfer.create','treasury_transfer.reverse',
      'settings.view','audit.view'
    ]::text[]) or jsonb_typeof(e.value) <> 'boolean'
  ) then raise exception 'INVALID_MEMBER_PERMISSIONS'; end if;

  select m.role into target_role from public.business_members m
  where m.business_id=p_business_id and m.user_id=p_user_id for update;
  if not found then raise exception 'MEMBER_NOT_FOUND'; end if;
  if target_role in ('owner','admin') then raise exception 'PROTECTED_MEMBER'; end if;

  update public.business_members
  set role=p_role, active=p_active, permissions=p_permissions
  where business_id=p_business_id and user_id=p_user_id;
end;
$function$;

revoke all on function public.update_business_member(uuid,uuid,text,boolean,jsonb) from public, anon, authenticated;
grant execute on function public.update_business_member(uuid,uuid,text,boolean,jsonb) to authenticated, service_role;

-- owner_remove_sales_return(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_remove_sales_return(p_business_id uuid, p_return_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_return record;
 v_invoice record;
 v_item record;
 v_stock record;
 v_refund_payment record;
 v_cash_tx record;
 v_cash_refund numeric(14,2):=0;
 v_credit_applied numeric(14,2):=0;
 v_reversal uuid;
 v_payment_reversal uuid;
 v_payment_count integer:=0;
 v_cash_count integer:=0;
 v_credit_created numeric(14,2):=0;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id
   and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can remove sales returns'; end if;

 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_return from public.sales_returns
 where id=p_return_id and business_id=p_business_id for update;
 if not found then raise exception 'Sales return not found'; end if;
 if v_return.status='void' then raise exception 'This sales return is already cancelled'; end if;

 select * into v_invoice from public.sales_invoices
 where id=v_return.sales_invoice_id and business_id=p_business_id for update;
 if not found or v_invoice.status='void' then raise exception 'Original sales invoice not found or cancelled'; end if;
 if exists(select 1 from public.customer_credit_ledger a where a.business_id=p_business_id and a.source_return_id=p_return_id and a.event_type in ('invoice_application','payout') and not exists(select 1 from public.customer_credit_ledger rv where rv.reversal_of_id=a.id)) then raise exception 'This return credit has already been used or paid out; reverse those operations before cancelling the return'; end if;

 perform 1 from public.products p
 where p.business_id=p_business_id
  and p.id in (select sri.product_id from public.sales_return_items sri
   where sri.business_id=p_business_id and sri.return_id=p_return_id)
 order by p.id for update;

 if exists(select 1 from public.sales_returns r where r.business_id=p_business_id
   and r.sales_invoice_id=v_invoice.id and r.id<>p_return_id
   and r.posted_at>v_return.posted_at and r.status='posted') then
  raise exception 'A later return exists for this invoice; cancel returns in reverse order first';
 end if;
 if exists(select 1 from public.payments p where p.business_id=p_business_id
   and p.invoice_id=v_invoice.id and p.posted_at>v_return.posted_at
   and p.sales_return_id is distinct from p_return_id) then
  raise exception 'Later invoice payments exist; cancellation is blocked to protect the account balance';
 end if;

 select count(*) into v_payment_count from public.payments
 where business_id=p_business_id and sales_return_id=p_return_id
   and direction='out';
 if exists(select 1 from public.cash_transactions where business_id=p_business_id and invoice_id=v_invoice.id and transaction_type='customer_refund' and direction='out' and sales_return_id is null) then raise exception 'Legacy cash refunds without a return link exist for this invoice; this return cannot be cancelled safely'; end if;
 if exists(select 1 from public.payments where business_id=p_business_id and invoice_id=v_invoice.id and direction='out' and method='cash' and sales_return_id is null) then raise exception 'Legacy cash refund payment without a return link exists; this return cannot be cancelled safely'; end if;
 if v_payment_count>1 then raise exception 'Multiple cash refund payment records are linked to this return'; end if;

 select count(*) into v_cash_count from public.cash_transactions
 where business_id=p_business_id and sales_return_id=p_return_id
   and transaction_type='customer_refund' and direction='out';
 if v_cash_count not in (0,1) or (v_cash_count=1 and v_payment_count<>1) then raise exception 'The cash refund ledger does not match the return payment ledger; no changes were made'; end if;

 if v_payment_count>1 then raise exception 'Multiple refund payment records are linked to this return'; end if;
 if v_payment_count=1 then
  select * into v_refund_payment from public.payments where business_id=p_business_id and sales_return_id=p_return_id and direction='out' for update;
  if v_refund_payment.invoice_id<>v_invoice.id then raise exception 'The linked refund payment invoice does not match'; end if;
  if exists(select 1 from public.payments where reversal_of_payment_id=v_refund_payment.id) then raise exception 'This return refund has already been reversed'; end if;
  v_cash_refund:=v_refund_payment.amount;
  if v_refund_payment.method='cash' then
   if v_cash_count<>1 then raise exception 'The linked cash ledger entry is missing'; end if;
   select * into v_cash_tx from public.cash_transactions where business_id=p_business_id and sales_return_id=p_return_id and transaction_type='customer_refund' and direction='out' for update;
   if v_refund_payment.amount<>v_cash_tx.amount or v_cash_tx.invoice_id<>v_invoice.id then raise exception 'The linked cash refund amount or invoice does not match'; end if;
   if v_cash_tx.payment_id is not null and v_cash_tx.payment_id<>v_refund_payment.id then raise exception 'The cash refund is linked to a different payment'; end if;
   update public.cash_transactions set payment_id=v_refund_payment.id where id=v_cash_tx.id and payment_id is null;
   if exists(select 1 from public.cash_transactions where reversal_of_transaction_id=v_cash_tx.id) then raise exception 'This return cash refund has already been reversed'; end if;
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,reversal_of_transaction_id,sales_return_id,account_method)
   values(p_business_id,current_date,'in','deposit',v_cash_refund,v_invoice.customer_id,v_invoice.id,'عكس رد نقدي لمرتجع ملغى','عكس حركة رد المرتجع رقم '||v_return.return_no,auth.uid(),v_cash_tx.id,p_return_id,'cash') returning id into v_reversal;
  elsif v_cash_count<>0 then raise exception 'A non-cash refund unexpectedly has a cash ledger entry'; end if;
  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,notes,created_by,sales_return_id,reversal_of_payment_id)
  values(p_business_id,v_refund_payment.party_id,v_invoice.id,'in',v_cash_refund,current_date,v_refund_payment.method,'عكس رد المرتجع '||v_return.return_no,'عكس دفعة رد لمرتجع ملغى',auth.uid(),p_return_id,v_refund_payment.id) returning id into v_payment_reversal;
  if v_refund_payment.method='cash' and v_reversal is not null then
   update public.cash_transactions set payment_id=v_payment_reversal where id=v_reversal and payment_id is null;
  end if;
 end if;

 v_credit_applied:=coalesce(v_return.invoice_due_reduced_total,v_return.refund_total-v_cash_refund);
 if v_credit_applied<0 then raise exception 'Return refund allocation is inconsistent'; end if;
 select coalesce(sum(amount),0) into v_credit_created from public.customer_credit_ledger where business_id=p_business_id and source_return_id=p_return_id and event_type='return_credit';
 if v_credit_created>0 then
  if exists(select 1 from public.customer_credit_ledger where business_id=p_business_id and reversal_of_id in (select id from public.customer_credit_ledger where source_return_id=p_return_id and event_type='return_credit')) then raise exception 'Customer credit for this return was already reversed'; end if;
  insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,event_type,amount,reversal_of_id,created_by)
  select p_business_id,v_return.customer_id,p_return_id,'reversal',-v_credit_created,id,auth.uid() from public.customer_credit_ledger where business_id=p_business_id and source_return_id=p_return_id and event_type='return_credit';
 end if;

 perform 1 from public.sales_items si
  where si.business_id=p_business_id
   and si.id in (select sri.sales_item_id from public.sales_return_items sri
    where sri.business_id=p_business_id and sri.return_id=p_return_id)
  order by si.id for update;
 for v_item in
  select sri.sales_item_id,sum(sri.quantity) as return_qty,max(si.returned_quantity) as returned_quantity
  from public.sales_return_items sri
  join public.sales_items si on si.id=sri.sales_item_id and si.business_id=sri.business_id
  where sri.business_id=p_business_id and sri.return_id=p_return_id
  group by sri.sales_item_id
 loop
  if v_item.returned_quantity<v_item.return_qty then
   raise exception 'Return quantity data is inconsistent; no changes were made';
  end if;
  update public.sales_items set returned_quantity=returned_quantity-v_item.return_qty
   where id=v_item.sales_item_id and business_id=p_business_id;
 end loop;

 if exists(
  select 1
  from (
   select product_id,sum(quantity) qty from public.sales_return_items
   where business_id=p_business_id and return_id=p_return_id and condition='good'
   group by product_id
  ) good_items
  full join (
   select product_id,sum(quantity_delta) qty from public.stock_movements
   where business_id=p_business_id and source_type='sales_return' and source_id=p_return_id and stock_bucket='sellable'
   group by product_id
  ) movements using(product_id)
  where coalesce(good_items.qty,0)<>coalesce(movements.qty,0)
 ) then raise exception 'Returned stock movements do not match good-condition return items'; end if;

 if exists(
  select 1
  from (
   select product_id,sum(quantity) qty from public.sales_return_items
   where business_id=p_business_id and return_id=p_return_id and condition='damaged'
   group by product_id
  ) damaged_items
  full join (
   select product_id,sum(quantity_delta) qty from public.stock_movements
   where business_id=p_business_id and source_type='sales_return' and source_id=p_return_id and stock_bucket='damaged'
   group by product_id
  ) movements using(product_id)
  where coalesce(damaged_items.qty,0)<>coalesce(movements.qty,0)
 ) then raise exception 'Damaged return stock movements do not match damaged-condition return items'; end if;
 for v_stock in
  select * from public.stock_movements
  where business_id=p_business_id and source_type='sales_return' and source_id=p_return_id
  order by posted_at desc,id desc
  for update
 loop
  if v_stock.movement_type='customer_return_good' then
   if v_stock.average_cost_before is null then
    raise exception 'Cannot safely cancel this older good-condition return because its previous average cost was not recorded';
   end if;
   update public.products set average_cost=v_stock.average_cost_before,updated_at=now()
   where id=v_stock.product_id and business_id=p_business_id;
  end if;
  if exists(select 1 from public.stock_movements m where m.business_id=p_business_id
    and m.product_id=v_stock.product_id and m.posted_at>v_stock.posted_at and m.id<>v_stock.id
    and not(m.source_type='sales_return' and m.source_id=p_return_id)) then
   raise exception 'Later stock movements exist for a returned product; this return cannot be cancelled safely';
  end if;
  if exists(select 1 from public.stock_movements r where r.reversal_of_movement_id=v_stock.id) then
   raise exception 'A return stock movement has already been reversed';
  end if;
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by,reversal_of_movement_id,stock_bucket
  ) values(
   p_business_id,v_stock.product_id,current_date,'adjustment_out',-v_stock.quantity_delta,
   v_stock.unit_cost,'sales_return_reversal',v_stock.id,'عكس مرتجع مبيعات ملغى',auth.uid(),v_stock.id,v_stock.stock_bucket
  );
 end loop;

 update public.sales_invoices
 set paid_total=paid_total+v_cash_refund,
     due_total=due_total+v_credit_applied,
     status=case
      when not exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity<si.quantity) then 'returned'
      when exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity>0) then 'partially_returned'
      else 'posted' end
 where id=v_invoice.id and business_id=p_business_id;

 update public.sales_returns set status='void'
 where id=p_return_id and business_id=p_business_id;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void','sales_return',p_return_id,
  jsonb_build_object('invoice_id',v_invoice.id,'refund_total',v_return.refund_total,
   'cash_refund_reversed',v_cash_refund,'credit_restored',v_credit_applied,
   'cash_reversal_id',v_reversal,'payment_reversal_id',v_payment_reversal,
   'stock_reversed',true));
 return 'void';
end;
$function$;

revoke all on function public.owner_remove_sales_return(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_remove_sales_return(uuid,uuid) to authenticated, service_role;

-- owner_restore_party(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_restore_party(p_business_id uuid, p_party_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_kind text;
  v_active boolean;
begin
  if auth.uid() is null
     or not exists (
       select 1
       from public.business_members
       where business_id = p_business_id
         and user_id = auth.uid()
         and role = 'owner'
         and active
     ) then
    raise exception 'Only the active business owner can restore customers or suppliers';
  end if;

  select kind, is_active
    into v_kind, v_active
  from public.parties
  where id = p_party_id
    and business_id = p_business_id
  for update;

  if not found then
    raise exception 'Customer or supplier not found';
  end if;

  if v_kind not in ('customer', 'supplier', 'both') then
    raise exception 'This account is not a customer or supplier';
  end if;

  if v_active then
    return 'already_active';
  end if;

  update public.parties
  set is_active = true
  where id = p_party_id
    and business_id = p_business_id;

  insert into public.audit_log(business_id, actor_id, action, entity_type, entity_id, details)
  values (
    p_business_id,
    auth.uid(),
    'restored',
    'party',
    p_party_id,
    jsonb_build_object('kind', v_kind, 'restored_from_archive', true)
  );

  return 'restored';
end;
$function$;

revoke all on function public.owner_restore_party(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_restore_party(uuid,uuid) to authenticated, service_role;

-- owner_restore_product(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_restore_product(p_business_id uuid, p_product_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_is_active boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.business_members
    WHERE business_id = p_business_id
      AND user_id = auth.uid()
      AND role = 'owner'
      AND active = true
  ) THEN
    RAISE EXCEPTION 'Only the active business owner can restore products';
  END IF;

  SELECT is_active
    INTO v_is_active
  FROM public.products
  WHERE id = p_product_id
    AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Archived product not found';
  END IF;

  IF v_is_active THEN
    RAISE EXCEPTION 'Product is already active';
  END IF;

  UPDATE public.products
  SET is_active = true,
      updated_at = now()
  WHERE id = p_product_id
    AND business_id = p_business_id;

  INSERT INTO public.audit_log(
    business_id, actor_id, action, entity_type, entity_id, details
  )
  VALUES (
    p_business_id, auth.uid(), 'restored', 'product', p_product_id,
    jsonb_build_object('restored', true)
  );

  RETURN 'restored';
END;
$function$;

revoke all on function public.owner_restore_product(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_restore_product(uuid,uuid) to authenticated, service_role;

-- owner_reverse_customer_invoice_payment(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_reverse_customer_invoice_payment(p_business_id uuid, p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
 v_payment public.payments%rowtype;
 v_invoice public.sales_invoices%rowtype;
 v_cash public.cash_transactions%rowtype;
 v_reversal_id uuid;
 v_cash_matches integer;
 v_cash_balance numeric(14,2);
 v_method_balance numeric(14,2);
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS (
  SELECT 1 FROM public.business_members
  WHERE business_id=p_business_id AND user_id=auth.uid()
   AND active=true AND role='owner'
 ) THEN
  RAISE EXCEPTION 'Only the active business owner can reverse customer invoice payments';
 END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 SELECT * INTO v_payment FROM public.payments
 WHERE id=p_payment_id AND business_id=p_business_id
  AND invoice_id IS NOT NULL AND sales_return_id IS NULL
  AND direction='in' AND reversal_of_payment_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Customer invoice receipt not found'; END IF;
 IF EXISTS (SELECT 1 FROM public.payments WHERE reversal_of_payment_id=v_payment.id) THEN
  RAISE EXCEPTION 'This payment has already been reversed';
 END IF;
 SELECT * INTO v_invoice FROM public.sales_invoices
 WHERE id=v_payment.invoice_id AND business_id=p_business_id
  AND customer_id=v_payment.party_id FOR UPDATE;
 IF NOT FOUND OR v_invoice.status='void' THEN
  RAISE EXCEPTION 'Related active sales invoice not found';
 END IF;
 IF v_payment.amount<=0 OR v_payment.amount>v_invoice.paid_total THEN
  RAISE EXCEPTION 'Payment amount does not reconcile with the invoice balance';
 END IF;
 IF lower(v_payment.method)<>'cash' THEN
  SELECT COALESCE(SUM(CASE WHEN direction='in' THEN amount ELSE -amount END),0)
    + COALESCE((SELECT SUM(CASE WHEN destination_method=v_payment.method THEN amount
      WHEN source_method=v_payment.method THEN -amount ELSE 0 END)
      FROM public.treasury_transfers WHERE business_id=p_business_id),0)
    + COALESCE((SELECT SUM(CASE WHEN direction='in' THEN amount ELSE -amount END)
      FROM public.cash_transactions WHERE business_id=p_business_id
       AND lower(account_method)=lower(v_payment.method)
       AND payment_id IS NULL AND treasury_transfer_id IS NULL),0)
   INTO v_method_balance
  FROM public.payments WHERE business_id=p_business_id AND lower(method)=lower(v_payment.method);
  IF COALESCE(v_method_balance,0)<v_payment.amount THEN
   RAISE EXCEPTION 'Insufficient % balance to reverse this customer receipt. Available: %, required: %',
    v_payment.method,COALESCE(v_method_balance,0),v_payment.amount;
  END IF;
 END IF;
 IF lower(v_payment.method)='cash' THEN
  SELECT count(*) INTO v_cash_matches FROM public.cash_transactions
  WHERE business_id=p_business_id AND invoice_id=v_payment.invoice_id
   AND transaction_type='sale_payment' AND direction='in'
   AND amount=v_payment.amount AND (payment_id=v_payment.id OR payment_id IS NULL);
  IF v_cash_matches<>1 THEN
   RAISE EXCEPTION 'Could not uniquely match this cash receipt to its cash ledger entry';
  END IF;
  SELECT * INTO v_cash FROM public.cash_transactions
  WHERE business_id=p_business_id AND invoice_id=v_payment.invoice_id
   AND transaction_type='sale_payment' AND direction='in'
   AND amount=v_payment.amount AND (payment_id=v_payment.id OR payment_id IS NULL) FOR UPDATE;
  SELECT COALESCE(sum(CASE WHEN direction='in' THEN amount ELSE -amount END),0)
   INTO v_cash_balance FROM public.cash_transactions WHERE business_id=p_business_id;
  IF v_cash_balance<v_cash.amount THEN
   RAISE EXCEPTION 'Insufficient cash balance to reverse this customer receipt';
  END IF;
 ELSE
  IF EXISTS (SELECT 1 FROM public.cash_transactions WHERE business_id=p_business_id AND payment_id=v_payment.id) THEN
   RAISE EXCEPTION 'A non-cash receipt unexpectedly has a cash ledger entry';
  END IF;
 END IF;
 INSERT INTO public.payments(
  business_id,party_id,invoice_id,direction,amount,payment_date,method,
  reference,notes,created_by,reversal_of_payment_id
 ) VALUES(
  p_business_id,v_payment.party_id,v_payment.invoice_id,'out',v_payment.amount,
  current_date,v_payment.method,
  'عكس تحصيل '||COALESCE(v_payment.reference,v_payment.id::text),
  'قيد عكسي لتحصيل عميل على فاتورة مبيعات',auth.uid(),v_payment.id
 ) RETURNING id INTO v_reversal_id;
 IF lower(v_payment.method)='cash' THEN
  UPDATE public.cash_transactions SET payment_id=v_payment.id
  WHERE id=v_cash.id AND payment_id IS NULL;
  INSERT INTO public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id,payment_id
  ) VALUES(
   p_business_id,current_date,'out','other',v_cash.amount,v_cash.party_id,v_cash.invoice_id,
   'عكس تحصيل عميل','قيد عكسي لحركة الخزنة الأصلية رقم '||v_cash.id,
   auth.uid(),v_cash.id,v_reversal_id
  );
 END IF;
 -- Payment status is represented by paid_total/due_total; keep the invoice's
 -- posting/return status unchanged (the CHECK constraint has no partially_paid value).
 UPDATE public.sales_invoices
 SET paid_total=paid_total-v_payment.amount,
  due_total=due_total+v_payment.amount
 WHERE id=v_invoice.id AND business_id=p_business_id;
 INSERT INTO public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 VALUES(
  p_business_id,auth.uid(),'reverse_customer_invoice_payment','payment',v_payment.id,
  jsonb_build_object('reversal_payment_id',v_reversal_id,'invoice_id',v_invoice.id,
   'amount',v_payment.amount,'method',v_payment.method)
 );
 RETURN v_reversal_id;
END;
$function$;

revoke all on function public.owner_reverse_customer_invoice_payment(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_reverse_customer_invoice_payment(uuid,uuid) to authenticated, service_role;

-- owner_reverse_invoice_payment(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_reverse_invoice_payment(p_business_id uuid, p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE v_payment public.payments%rowtype; v_invoice public.purchase_invoices%rowtype;
 v_cash public.cash_transactions%rowtype; v_reversal_id uuid; v_cash_matches integer;
BEGIN
 IF auth.uid() IS NULL OR NOT EXISTS(SELECT 1 FROM public.business_members
  WHERE business_id=p_business_id AND user_id=auth.uid() AND active=true AND role='owner')
 THEN RAISE EXCEPTION 'Only the active business owner can reverse invoice payments'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 SELECT * INTO v_payment FROM public.payments WHERE id=p_payment_id AND business_id=p_business_id
  AND invoice_id IS NOT NULL AND sales_return_id IS NULL AND direction='out'
  AND reversal_of_payment_id IS NULL FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Supplier invoice payment not found'; END IF;
 IF EXISTS(SELECT 1 FROM public.payments WHERE reversal_of_payment_id=v_payment.id)
 THEN RAISE EXCEPTION 'This payment has already been reversed'; END IF;
 SELECT * INTO v_invoice FROM public.purchase_invoices WHERE id=v_payment.invoice_id
  AND business_id=p_business_id AND supplier_id=v_payment.party_id FOR UPDATE;
 IF NOT FOUND OR v_invoice.status='void' THEN RAISE EXCEPTION 'Related active purchase invoice not found'; END IF;
 IF v_payment.amount<=0 OR v_payment.amount>v_invoice.paid_total THEN
  RAISE EXCEPTION 'Payment amount does not reconcile with the invoice balance'; END IF;
 IF lower(v_payment.method)='cash' THEN
  SELECT count(*) INTO v_cash_matches FROM public.cash_transactions
   WHERE business_id=p_business_id AND invoice_id=v_payment.invoice_id
    AND transaction_type='purchase_payment' AND direction='out' AND amount=v_payment.amount
    AND (payment_id=v_payment.id OR payment_id IS NULL);
  IF v_cash_matches<>1 THEN RAISE EXCEPTION 'Could not uniquely match this cash payment to its cash ledger entry'; END IF;
  SELECT * INTO v_cash FROM public.cash_transactions WHERE business_id=p_business_id
   AND invoice_id=v_payment.invoice_id AND transaction_type='purchase_payment' AND direction='out'
   AND amount=v_payment.amount AND (payment_id=v_payment.id OR payment_id IS NULL) FOR UPDATE;
 ELSE
  IF EXISTS(SELECT 1 FROM public.cash_transactions WHERE business_id=p_business_id AND payment_id=v_payment.id)
  THEN RAISE EXCEPTION 'Non-cash payment unexpectedly has a cash ledger entry'; END IF;
 END IF;
 INSERT INTO public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,notes,created_by,reversal_of_payment_id)
 VALUES(p_business_id,v_payment.party_id,v_payment.invoice_id,'in',v_payment.amount,current_date,v_payment.method,
  'عكس دفعة '||coalesce(v_payment.reference,v_payment.id::text),'قيد عكسي لدفعة مورد',auth.uid(),v_payment.id)
 RETURNING id INTO v_reversal_id;
 IF lower(v_payment.method)='cash' THEN
  UPDATE public.cash_transactions SET payment_id=v_payment.id WHERE id=v_cash.id AND payment_id IS NULL;
  INSERT INTO public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id,payment_id)
  VALUES(p_business_id,current_date,'in','deposit',v_cash.amount,v_cash.party_id,v_cash.invoice_id,
   'عكس سداد مورد','قيد عكسي لحركة الخزنة الأصلية رقم '||v_cash.id,auth.uid(),v_cash.id,v_reversal_id);
 END IF;
 UPDATE public.purchase_invoices SET paid_total=paid_total-v_payment.amount,
  due_total=due_total+v_payment.amount,
  status=CASE WHEN paid_total-v_payment.amount<=0 THEN 'posted' ELSE 'partially_paid' END
 WHERE id=v_invoice.id AND business_id=p_business_id;
 INSERT INTO public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 VALUES(p_business_id,auth.uid(),'reverse_invoice_payment','payment',v_payment.id,
  jsonb_build_object('reversal_payment_id',v_reversal_id,'invoice_id',v_invoice.id,
   'amount',v_payment.amount,'method',v_payment.method));
 RETURN v_reversal_id;
END;$function$;

revoke all on function public.owner_reverse_invoice_payment(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_reverse_invoice_payment(uuid,uuid) to authenticated, service_role;

-- owner_reverse_standalone_party_payment(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_reverse_standalone_party_payment(p_business_id uuid, p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_payment public.payments%rowtype;
 v_cash public.cash_transactions%rowtype;
 v_reversal_id uuid;
 v_cash_balance numeric(14,2);
 v_method_balance numeric(14,2);
 v_credit_event record;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and active=true and role='owner'
 ) then raise exception 'Only the active business owner can reverse a standalone payment'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_payment from public.payments
 where id=p_payment_id and business_id=p_business_id and invoice_id is null
  and sales_return_id is null and party_account_type in ('customer','supplier')
  and reversal_of_payment_id is null for update;
 if not found then raise exception 'Standalone payment not found'; end if;
 if exists(select 1 from public.payments where reversal_of_payment_id=v_payment.id) then
  raise exception 'This payment has already been reversed';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 if v_payment.direction='in' and lower(v_payment.method)<>'cash' then
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   + coalesce((select sum(case when destination_method=v_payment.method then amount
     when source_method=v_payment.method then -amount else 0 end)
     from public.treasury_transfers where business_id=p_business_id),0)
   + coalesce((select sum(case when direction='in' then amount else -amount end)
     from public.cash_transactions where business_id=p_business_id
      and lower(account_method)=lower(v_payment.method)
      and payment_id is null and treasury_transfer_id is null),0)
   into v_method_balance
  from public.payments where business_id=p_business_id and lower(method)=lower(v_payment.method);
  if coalesce(v_method_balance,0)<v_payment.amount then
   raise exception 'Insufficient % balance to reverse this customer receipt. Available: %, required: %',
    v_payment.method,coalesce(v_method_balance,0),v_payment.amount;
  end if;
 end if;
 if lower(v_payment.method)='cash' then
  select * into v_cash from public.cash_transactions
  where business_id=p_business_id and payment_id=v_payment.id for update;
  if not found or v_cash.amount<>v_payment.amount or v_cash.direction<>v_payment.direction then
   raise exception 'The payment does not reconcile with its cash ledger entry';
  end if;
  select coalesce(balance,0) into v_cash_balance from public.cash_balances where business_id=p_business_id;
  if v_cash.direction='in' and v_cash_balance<v_cash.amount then
   raise exception 'Insufficient cash balance to reverse this receipt';
  end if;
 else
  if exists(select 1 from public.cash_transactions where business_id=p_business_id and payment_id=v_payment.id) then
   raise exception 'A non-cash payment unexpectedly has a cash ledger entry';
  end if;
 end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by,reversal_of_payment_id)
 values(p_business_id,v_payment.party_id,null,v_payment.party_account_type,
  case when v_payment.direction='in' then 'out' else 'in' end,
  v_payment.amount,current_date,v_payment.method,
  'عكس دفعة '||coalesce(v_payment.reference,v_payment.id::text),
  'قيد عكسي لدفعة مستقلة',auth.uid(),v_payment.id)
 returning id into v_reversal_id;
 if lower(v_payment.method)='cash' then
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id,payment_id)
  values(p_business_id,current_date,case when v_cash.direction='in' then 'out' else 'in' end,
   case when v_cash.direction='in' then 'other' else 'deposit' end,
   v_cash.amount,v_cash.party_id,null,'عكس دفعة مستقلة', 'عكس حركة الخزنة الأصلية رقم '||v_cash.id,
   auth.uid(),v_cash.id,v_reversal_id);
 end if;
 if v_payment.party_account_type='customer' then
  for v_credit_event in select * from public.customer_credit_ledger where business_id=p_business_id and payment_id=v_payment.id and event_type='payout' and not exists(select 1 from public.customer_credit_ledger rv where rv.reversal_of_id=customer_credit_ledger.id) for update loop
   insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,event_type,amount,reversal_of_id,created_by)
   values(p_business_id,v_credit_event.customer_id,v_credit_event.source_return_id,'reversal',-v_credit_event.amount,v_credit_event.id,auth.uid());
  end loop;
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'reverse_standalone_payment','payment',v_payment.id,
  jsonb_build_object('reversal_payment_id',v_reversal_id,'amount',v_payment.amount,'method',v_payment.method));
 return v_reversal_id;
end;
$function$;

revoke all on function public.owner_reverse_standalone_party_payment(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_reverse_standalone_party_payment(uuid,uuid) to authenticated, service_role;

-- owner_void_invoice(uuid,text,uuid)
CREATE OR REPLACE FUNCTION public.owner_void_invoice(p_business_id uuid, p_invoice_type text, p_invoice_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_invoice record;
 v_cash_total numeric(14,2) := 0;
 v_cash_balance numeric(14,2) := 0;
 v_payment record;
 v_cash_tx record;
 v_payment_cash numeric(14,2) := 0;
 v_cash_ledger numeric(14,2) := 0;
 v_payment_reversal_id uuid;
 v_cash_reversal_id uuid;
 v_credit_application record;
begin
 if auth.uid() is null or not exists (
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid()
    and role='owner' and active
 ) then
  raise exception 'Only the active business owner can cancel invoices';
 end if;
 if p_invoice_type not in ('sale','purchase') then
  raise exception 'Unsupported invoice type';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

 if p_invoice_type='sale' then
  select * into v_invoice from public.sales_invoices
  where id=p_invoice_id and business_id=p_business_id for update;
 else
  select * into v_invoice from public.purchase_invoices
  where id=p_invoice_id and business_id=p_business_id for update;
 end if;
 if not found then raise exception 'Invoice not found in this business'; end if;
 if v_invoice.status='void' then raise exception 'Invoice is already cancelled'; end if;

 if p_invoice_type='sale' then
  perform 1 from public.products p
  join public.sales_items i on i.business_id=p.business_id and i.product_id=p.id
  where p.business_id=p_business_id and i.invoice_id=p_invoice_id
  order by p.id for update of p;
  if exists(select 1 from public.sales_returns where business_id=p_business_id and sales_invoice_id=p_invoice_id and status<>'void') then raise exception 'Cannot cancel an invoice with active returns; cancel the returns first'; end if;
  perform 1 from public.customer_credit_ledger where business_id=p_business_id and invoice_id=p_invoice_id for update;
  if exists(select 1 from public.customer_credit_ledger a where a.business_id=p_business_id and a.invoice_id=p_invoice_id and a.event_type='invoice_application' and not exists(select 1 from public.customer_credit_ledger rv where rv.reversal_of_id=a.id)) then
   for v_credit_application in select * from public.customer_credit_ledger a where a.business_id=p_business_id and a.invoice_id=p_invoice_id and a.event_type='invoice_application' and not exists(select 1 from public.customer_credit_ledger rv where rv.reversal_of_id=a.id) for update loop
    insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,invoice_id,event_type,amount,reversal_of_id,created_by)
    values(p_business_id,v_credit_application.customer_id,v_credit_application.source_return_id,p_invoice_id,'reversal',-v_credit_application.amount,v_credit_application.id,auth.uid());
   end loop;
  end if;
  if exists(
   select 1 from public.stock_movements m
   join public.sales_items i on i.business_id=m.business_id and i.product_id=m.product_id
   where m.business_id=p_business_id and i.invoice_id=p_invoice_id
    and m.posted_at>(select max(sm.posted_at) from public.stock_movements sm
      where sm.business_id=p_business_id and sm.product_id=m.product_id
       and sm.source_type='sale' and sm.source_id=p_invoice_id)
    and not (m.source_type='sale' and m.source_id=p_invoice_id)
  ) then
   raise exception 'Cannot cancel this sale: later stock movements exist for one or more products';
  end if;
 else
  perform 1 from public.products p
  join public.purchase_items i on i.business_id=p.business_id and i.product_id=p.id
  where p.business_id=p_business_id and i.invoice_id=p_invoice_id
  order by p.id for update of p;
  if exists(
   select 1 from public.stock_movements m
   join public.purchase_items i on i.business_id=m.business_id and i.product_id=m.product_id
   where m.business_id=p_business_id and i.invoice_id=p_invoice_id
    and m.posted_at>(select max(sm.posted_at) from public.stock_movements sm
      where sm.business_id=p_business_id and sm.product_id=m.product_id
       and sm.source_type='purchase' and sm.source_id=p_invoice_id)
    and not (m.source_type='purchase' and m.source_id=p_invoice_id)
  ) then
   raise exception 'Cannot cancel this purchase: later stock movements exist for one or more products';
  end if;
  if exists(
   select 1 from public.purchase_items i
   left join public.purchase_invoice_cost_snapshots s
    on s.business_id=i.business_id and s.invoice_id=i.invoice_id and s.product_id=i.product_id
   where i.business_id=p_business_id and i.invoice_id=p_invoice_id and s.product_id is null
  ) then
   raise exception 'This older purchase has no cost snapshot and cannot be safely cancelled';
  end if;
 end if;

 -- Payment history is immutable: verify that cash payment rows match their cash-ledger rows.
 if p_invoice_type='sale' then
  select coalesce(sum(amount),0) into v_payment_cash
  from public.payments
  where business_id=p_business_id and invoice_id=p_invoice_id
    and direction='in' and lower(method)='cash' and sales_return_id is null
    and reversal_of_payment_id is null
    and not exists(select 1 from public.payments pr where pr.reversal_of_payment_id=payments.id);
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='sale_payment' and direction='in'
    and reversal_of_transaction_id is null
    and not exists(select 1 from public.cash_transactions cr where cr.reversal_of_transaction_id=cash_transactions.id);
 else
  select coalesce(sum(amount),0) into v_payment_cash
  from public.payments
  where business_id=p_business_id and invoice_id=p_invoice_id
    and direction='out' and lower(method)='cash' and sales_return_id is null
    and reversal_of_payment_id is null
    and not exists(select 1 from public.payments pr where pr.reversal_of_payment_id=payments.id);
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='purchase_payment' and direction='out'
    and reversal_of_transaction_id is null
    and not exists(select 1 from public.cash_transactions cr where cr.reversal_of_transaction_id=cash_transactions.id);
 end if;
 if v_payment_cash<>v_cash_ledger then
  raise exception 'Cash payment history does not reconcile with the cash ledger; invoice was not changed';
 end if;
 v_cash_total:=v_cash_ledger;

 if p_invoice_type='sale' then
  select coalesce(balance,0) into v_cash_balance from public.cash_balances where business_id=p_business_id;
  if v_cash_total>v_cash_balance then
   raise exception 'Cash balance is insufficient to reverse cash receipts. Record a cash deposit first.';
  end if;
  IF EXISTS (
   SELECT 1
   FROM (
    SELECT lower(p.method) AS method, sum(p.amount) AS amount
    FROM public.payments p
    WHERE p.business_id=p_business_id AND p.invoice_id=p_invoice_id
      AND p.direction='in' AND p.sales_return_id IS NULL
      AND p.reversal_of_payment_id IS NULL
      AND NOT EXISTS (SELECT 1 FROM public.payments pr WHERE pr.reversal_of_payment_id=p.id)
    GROUP BY lower(p.method)
   ) receipts
   WHERE receipts.method<>'cash'
     AND receipts.amount > (
      SELECT COALESCE(SUM(CASE WHEN p.direction='in' THEN p.amount ELSE -p.amount END),0)
       + COALESCE((SELECT SUM(CASE WHEN t.destination_method=receipts.method THEN t.amount
          WHEN t.source_method=receipts.method THEN -t.amount ELSE 0 END)
          FROM public.treasury_transfers t WHERE t.business_id=p_business_id),0)
      + COALESCE((SELECT SUM(CASE WHEN c.direction='in' THEN c.amount ELSE -c.amount END)
          FROM public.cash_transactions c
          WHERE c.business_id=p_business_id AND lower(c.account_method)=receipts.method
            AND c.payment_id IS NULL AND c.treasury_transfer_id IS NULL),0)
      FROM public.payments p
      WHERE p.business_id=p_business_id AND lower(p.method)=receipts.method
     )
  ) THEN
   RAISE EXCEPTION 'Cannot cancel this sale: one or more non-cash balances are insufficient to reverse its receipts';
  END IF;
 end if;

 -- Reverse each payment row rather than deleting it, including non-cash payments.
 for v_payment in
  select p.* from public.payments p
  where p.business_id=p_business_id and p.invoice_id=p_invoice_id
    and p.sales_return_id is null
    and p.reversal_of_payment_id is null
    and not exists(select 1 from public.payments pr where pr.reversal_of_payment_id=p.id)
  order by p.created_at,p.id for update
 loop
  insert into public.payments(
   business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,
   notes,created_by,reversal_of_payment_id
  ) values(
   p_business_id,v_payment.party_id,p_invoice_id,
   case when v_payment.direction='in' then 'out' else 'in' end,
   v_payment.amount,current_date,v_payment.method,
   'عكس دفعة '||coalesce(v_payment.reference,v_payment.id::text),
   'قيد عكسي لدفعة فاتورة ملغاة',auth.uid(),v_payment.id
  ) returning id into v_payment_reversal_id;
 end loop;

 -- Reverse each original cash movement with a traceable one-to-one pointer.
 for v_cash_tx in
  select * from public.cash_transactions
  where cash_transactions.business_id=p_business_id and cash_transactions.invoice_id=p_invoice_id
    and cash_transactions.transaction_type=case when p_invoice_type='sale' then 'sale_payment' else 'purchase_payment' end
    and cash_transactions.reversal_of_transaction_id is null
    and not exists(select 1 from public.cash_transactions cr where cr.reversal_of_transaction_id=cash_transactions.id)
  order by cash_transactions.created_at,cash_transactions.id for update
 loop
  insert into public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id
  ) values(
   p_business_id,current_date,
   case when v_cash_tx.direction='in' then 'out' else 'in' end,
   case when v_cash_tx.direction='in' then 'other' else 'deposit' end,
   v_cash_tx.amount,v_cash_tx.party_id,p_invoice_id,
   'عكس حركة دفعة فاتورة ملغاة',
   'عكس حركة الخزنة الأصلية رقم '||v_cash_tx.id,auth.uid(),v_cash_tx.id
  ) returning id into v_cash_reversal_id;
 end loop;

 if p_invoice_type='sale' then
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by
  )
  select business_id,product_id,current_date,'adjustment_in',quantity,unit_cost_snapshot,
   'sale_void',p_invoice_id,'عكس مخزون فاتورة مبيعات ملغاة',auth.uid()
  from public.sales_items where business_id=p_business_id and invoice_id=p_invoice_id;
  update public.sales_invoices set status='void',paid_total=0,due_total=0
   where id=p_invoice_id and business_id=p_business_id;
 else
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by
  )
  select business_id,product_id,current_date,'adjustment_out',-quantity,unit_landed_cost,
   'purchase_void',p_invoice_id,'عكس مخزون فاتورة مشتريات ملغاة',auth.uid()
  from public.purchase_items where business_id=p_business_id and invoice_id=p_invoice_id;
  update public.products p set average_cost=s.average_cost_before,updated_at=now()
   from public.purchase_invoice_cost_snapshots s
   where s.business_id=p_business_id and s.invoice_id=p_invoice_id
     and p.id=s.product_id and p.business_id=p_business_id;
  update public.purchase_invoices set status='void',paid_total=0,due_total=0
   where id=p_invoice_id and business_id=p_business_id;
 end if;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void',p_invoice_type||'_invoice',p_invoice_id,
  jsonb_build_object('invoice_no',v_invoice.invoice_no,'cash_reversed',v_cash_total,
   'payment_history_preserved',true));
 return 'void';
end;
$function$;

revoke all on function public.owner_void_invoice(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.owner_void_invoice(uuid,text,uuid) to authenticated, service_role;

-- owner_void_purchase_return(uuid,uuid)
CREATE OR REPLACE FUNCTION public.owner_void_purchase_return(p_business_id uuid, p_return_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_return public.purchase_returns%rowtype; v_invoice public.purchase_invoices%rowtype;
 v_payment public.payments%rowtype; v_cash public.cash_transactions%rowtype;
 v_stock public.stock_movements%rowtype; v_product public.products%rowtype;
 v_payment_count integer:=0; v_cash_count integer:=0; v_refund numeric(14,2):=0;
 v_available numeric(14,2):=0; v_invoice_restore numeric(14,2):=0;
 v_payment_reversal uuid; v_cash_reversal uuid; v_total_on_hand numeric(14,3);
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can cancel purchase returns'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_return from public.purchase_returns
  where id=p_return_id and business_id=p_business_id for update;
 if not found then raise exception 'Purchase return not found'; end if;
 if v_return.status='void' then raise exception 'This purchase return is already cancelled'; end if;
 if v_return.status<>'posted' then raise exception 'Only a posted purchase return can be cancelled'; end if;
 if v_return.invoice_due_reduced_total is null then
  raise exception 'This older purchase return has no saved invoice allocation snapshot and cannot be safely cancelled automatically';
 end if;
 select * into v_invoice from public.purchase_invoices
  where id=v_return.purchase_invoice_id and business_id=p_business_id for update;
 if not found or v_invoice.status='void' then raise exception 'Original purchase invoice not found or cancelled'; end if;
 if coalesce(v_return.credit_generated_total,0)>0 and exists(
  select 1 from public.purchase_invoices pi where pi.business_id=p_business_id and pi.supplier_id=v_return.supplier_id
   and pi.status<>'void' and (pi.created_at,pi.id)>(v_return.created_at,v_return.id)
   and coalesce(pi.supplier_credit_applied_total,0)>0
 ) then raise exception 'Supplier credit from this return may already have been applied to a later purchase invoice; cancel or reconcile the later invoice first'; end if;
 if coalesce(v_return.credit_generated_total,0)>0 and exists(
  select 1 from public.payments p where p.business_id=p_business_id and p.party_id=v_return.supplier_id
   and p.party_account_type='supplier' and p.invoice_id is null and p.direction='in'
   and p.created_at>v_return.created_at and p.reversal_of_payment_id is null
   and not exists(select 1 from public.payments rv where rv.reversal_of_payment_id=p.id and rv.business_id=p_business_id)
 ) then raise exception 'Supplier credit may already have been received after this return; reverse that receipt first'; end if;
 if exists(select 1 from public.purchase_returns r where r.business_id=p_business_id
  and r.supplier_id=v_return.supplier_id and r.id<>p_return_id and r.status='posted'
  and (r.posted_at,r.id)>(v_return.posted_at,v_return.id)) then
  raise exception 'A later purchase return exists for this supplier; cancel returns in reverse order first';
 end if;
 perform 1 from public.products p where p.business_id=p_business_id
  and p.id in (select distinct pri.product_id from public.purchase_return_items pri
   where pri.business_id=p_business_id and pri.return_id=p_return_id) order by p.id for update;
 if exists(
  select 1
  from (select product_id,case when condition='damaged' then 'damaged' else 'sellable' end bucket,sum(quantity) qty
        from public.purchase_return_items where business_id=p_business_id and return_id=p_return_id group by product_id,bucket) ri
  full join (select product_id,stock_bucket bucket,sum(-quantity_delta) qty from public.stock_movements
        where business_id=p_business_id and source_type='purchase_return' and source_id=p_return_id group by product_id,stock_bucket) sm
  using(product_id,bucket)
  where coalesce(ri.qty,0)<>coalesce(sm.qty,0)
 ) then raise exception 'Purchase return stock movements do not match the return items';
 end if;
 for v_stock in select * from public.stock_movements
  where business_id=p_business_id and source_type='purchase_return' and source_id=p_return_id
  order by posted_at desc,id desc for update
 loop
  if exists(select 1 from public.stock_movements m where m.business_id=p_business_id
   and m.product_id=v_stock.product_id and (m.posted_at,m.id)>(v_stock.posted_at,v_stock.id)
   and not(m.source_type='purchase_return' and m.source_id=p_return_id)) then
   raise exception 'Later stock movements exist for a returned product; this return cannot be cancelled safely';
  end if;
  if exists(select 1 from public.stock_movements m where m.reversal_of_movement_id=v_stock.id) then
   raise exception 'A purchase return stock movement has already been reversed';
  end if;
  select * into v_product from public.products where id=v_stock.product_id and business_id=p_business_id for update;
  select coalesce(sum(quantity_delta),0) into v_total_on_hand from public.stock_movements
   where business_id=p_business_id and product_id=v_stock.product_id;
  if v_total_on_hand>0 then
   update public.products set average_cost=round(greatest(0,
    ((v_total_on_hand*coalesce(v_product.average_cost,0))+((-v_stock.quantity_delta)*v_stock.unit_cost))
     /(v_total_on_hand+(-v_stock.quantity_delta))),2),updated_at=now()
   where id=v_stock.product_id and business_id=p_business_id;
  end if;
  insert into public.stock_movements(business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
   source_type,source_id,notes,created_by,reversal_of_movement_id,stock_bucket)
  values(p_business_id,v_stock.product_id,current_date,'adjustment_in',-v_stock.quantity_delta,v_stock.unit_cost,
   'purchase_return_reversal',p_return_id,'عكس مرتجع مشتريات ملغى',auth.uid(),v_stock.id,v_stock.stock_bucket);
 end loop;
 select count(*) into v_payment_count from public.payments
  where business_id=p_business_id and purchase_return_id=p_return_id and reversal_of_payment_id is null;
 if v_payment_count>1 then raise exception 'Multiple supplier refund payments are linked to this return'; end if;
 select count(*) into v_cash_count from public.cash_transactions
  where business_id=p_business_id and purchase_return_id=p_return_id and reversal_of_transaction_id is null;
 if v_payment_count=0 and v_cash_count<>0 then raise exception 'Cash ledger exists without its supplier refund payment';
 elsif v_payment_count=1 then
  select * into v_payment from public.payments
   where business_id=p_business_id and purchase_return_id=p_return_id and reversal_of_payment_id is null for update;
  if v_payment.direction<>'in' or v_payment.party_id<>v_return.supplier_id
   or v_payment.invoice_id<>v_return.purchase_invoice_id then
   raise exception 'Linked supplier refund payment does not match the purchase return';
  end if;
  if exists(select 1 from public.payments where reversal_of_payment_id=v_payment.id) then
   raise exception 'This supplier refund payment has already been reversed';
  end if;
  v_refund:=v_payment.amount;
  if v_payment.method='cash' then
   if v_cash_count<>1 then raise exception 'The linked cash refund ledger entry is missing'; end if;
   select * into v_cash from public.cash_transactions
    where business_id=p_business_id and purchase_return_id=p_return_id and reversal_of_transaction_id is null for update;
   if v_cash.direction<>'in' or v_cash.amount<>v_refund or v_cash.payment_id<>v_payment.id
    or v_cash.invoice_id<>v_invoice.id or v_cash.account_method<>'cash' then
    raise exception 'The linked cash refund amount or invoice does not match';
   end if;
   if exists(select 1 from public.cash_transactions where reversal_of_transaction_id=v_cash.id) then
    raise exception 'This cash refund has already been reversed';
   end if;
  elsif v_cash_count<>0 then raise exception 'A non-cash refund unexpectedly has a cash ledger entry';
  end if;
  if v_payment.method='cash' then
   if not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to reverse cash received'; end if;
   select coalesce(balance,0) into v_available from public.cash_balances where business_id=p_business_id;
  else
   if not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to reverse this payment method'; end if;
   select coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
      from public.payments p where p.business_id=p_business_id and lower(p.method)=lower(v_payment.method)),0)
    +coalesce((select sum(case when t.destination_method=lower(v_payment.method) then t.amount
      when t.source_method=lower(v_payment.method) then -t.amount else 0 end)
      from public.treasury_transfers t where t.business_id=p_business_id),0)
    +coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
      from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_payment.method) and c.payment_id is null and c.treasury_transfer_id is null),0)
    into v_available;
  end if;
  v_available:=coalesce(v_available,0);
  if v_available<v_refund then
   raise exception 'Insufficient balance in the original refund account to cancel this return. Available: %, required: %',v_available,v_refund;
  end if;
  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,notes,
   created_by,reversal_of_payment_id,party_account_type,purchase_return_id)
  values(p_business_id,v_payment.party_id,v_payment.invoice_id,'out',v_refund,current_date,v_payment.method,
   'عكس مرتجع مشتريات '||v_return.return_no,'عكس استرداد المورد لمرتجع مشتريات ملغى',auth.uid(),
   v_payment.id,'supplier',p_return_id) returning id into v_payment_reversal;
  if v_payment.method='cash' then
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
    reason,notes,created_by,payment_id,reversal_of_transaction_id,purchase_return_id,account_method)
   values(p_business_id,current_date,'out','expense',v_refund,v_return.supplier_id,v_invoice.id,
    'عكس مبلغ مستلم من المورد لمرتجع ملغى','عكس حركة مرتجع المشتريات '||v_return.return_no,auth.uid(),
    v_payment_reversal,v_cash.id,p_return_id,'cash') returning id into v_cash_reversal;
  end if;
 end if;
 v_invoice_restore:=coalesce(v_return.invoice_due_reduced_total,0);
 update public.purchase_invoices set due_total=due_total+v_invoice_restore,
  status=case when due_total+v_invoice_restore=0 then case when paid_total>0 then 'paid' else 'posted' end
   when paid_total>0 then 'partially_paid' else 'posted' end
 where id=v_invoice.id and business_id=p_business_id;
 update public.purchase_returns set status='void' where id=p_return_id and business_id=p_business_id;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'void','purchase_return',p_return_id,
  jsonb_build_object('invoice_id',v_invoice.id,'supplier_id',v_return.supplier_id,'total',v_return.total,
   'invoice_due_restored',v_invoice_restore,'refund_reversed',v_refund,
   'payment_reversal_id',v_payment_reversal,'cash_reversal_id',v_cash_reversal,'stock_reversed',true));
 return 'void';
end;
$function$;

revoke all on function public.owner_void_purchase_return(uuid,uuid) from public, anon, authenticated;
grant execute on function public.owner_void_purchase_return(uuid,uuid) to authenticated, service_role;

commit;

-- Important behavioral review:
-- * owner_remove_party and owner_remove_product physically delete only records with no operational history;
--   otherwise they archive by setting is_active=false.
-- * owner_remove_cash_opening_balance physically deletes only the sole opening cash row when no other
--   cash movement exists; it writes an audit entry first.
-- * owner_remove_cash_transaction creates a linked reversal and refuses invoice/expense/refund/opening links.
-- * owner_remove_expense validates the linked cash row and marks the expense void with a reversal.
-- * owner_remove_party_opening_balance refuses removal after account activity.
-- * invoice/return/payment void/reversal operations append compensating entries and preserve history.
-- * reset_business_data and restore_business_backup remain separate high-risk owner-only functions.
-- This draft has not been executed on Test or Production.
