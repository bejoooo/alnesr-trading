-- DRAFT PATCH: apply after PRODUCTION_HELPER_FUNCTIONS_TRIGGERS_DRAFT.sql.
begin;
set local search_path=pg_catalog,public;

create or replace function public.next_operation_code(p_business_id uuid,p_operation_type text)
returns text language plpgsql security definer set search_path=''
as $function$
declare v_number bigint; v_max bigint;
begin
 if p_business_id is null or auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id and user_id=auth.uid() and active
 ) then raise exception 'Not authorized'; end if;
 if p_operation_type is null or p_operation_type not in(
  'purchase_invoice','sales_invoice','sales_return','purchase_return','party','payment',
  'cash_transaction','expense','treasury_transfer','stock_movement'
 ) then raise exception 'Unsupported operation type'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||':'||p_operation_type,0));
 v_max:=case p_operation_type
 when 'purchase_invoice' then (select max(substring(invoice_no from 7)::bigint) from public.purchase_invoices where business_id=p_business_id and invoice_no~'^[0-9]{6}[0-9]+$')
 when 'sales_invoice' then (select max(substring(invoice_no from 7)::bigint) from public.sales_invoices where business_id=p_business_id and invoice_no~'^[0-9]{6}[0-9]+$')
 when 'sales_return' then (select max(substring(return_no from 7)::bigint) from public.sales_returns where business_id=p_business_id and return_no~'^[0-9]{6}[0-9]+$')
 when 'purchase_return' then (select max(substring(return_no from 7)::bigint) from public.purchase_returns where business_id=p_business_id and return_no~'^[0-9]{6}[0-9]+$')
 when 'party' then (select max(substring(party_code from 7)::bigint) from public.parties where business_id=p_business_id and party_code~'^[0-9]{6}[0-9]+$')
 when 'payment' then (select max(substring(payment_code from 7)::bigint) from public.payments where business_id=p_business_id and payment_code~'^[0-9]{6}[0-9]+$')
 when 'cash_transaction' then (select max(substring(transaction_code from 7)::bigint) from public.cash_transactions where business_id=p_business_id and transaction_code~'^[0-9]{6}[0-9]+$')
 when 'expense' then (select max(substring(expense_code from 7)::bigint) from public.expenses where business_id=p_business_id and expense_code~'^[0-9]{6}[0-9]+$')
 when 'treasury_transfer' then (select max(substring(transfer_code from 7)::bigint) from public.treasury_transfers where business_id=p_business_id and transfer_code~'^[0-9]{6}[0-9]+$')
 when 'stock_movement' then (select max(substring(movement_code from 7)::bigint) from public.stock_movements where business_id=p_business_id and movement_code~'^[0-9]{6}[0-9]+$')
 end;
 select last_number into v_number from public.operation_counters where business_id=p_business_id and operation_type=p_operation_type for update;
 if not found then
  insert into public.operation_counters(business_id,operation_type,last_number) values(p_business_id,p_operation_type,coalesce(v_max,0)+1) returning last_number into v_number;
 else
  update public.operation_counters set last_number=greatest(last_number,coalesce(v_max,0))+1,updated_at=clock_timestamp()
  where business_id=p_business_id and operation_type=p_operation_type returning last_number into v_number;
 end if;
 return to_char(timezone('Africa/Cairo',clock_timestamp()),'DDMMYY')||v_number::text;
end
$function$;

create or replace function public.assign_automatic_invoice_number()
returns trigger language plpgsql security invoker set search_path=''
as $function$
declare v_kind text; v_next bigint;
begin
 if upper(trim(coalesce(new.invoice_no,''))) not in('AUTO','تلقائي') then return new; end if;
 if tg_table_name='sales_invoices' then
  v_kind:='sales';
  perform pg_advisory_xact_lock(hashtextextended(new.business_id::text||':invoice:'||v_kind,0));
  select coalesce(max((substring(s.invoice_no from '([0-9]+)$'))::bigint),0)+1 into v_next
  from public.sales_invoices s where s.business_id=new.business_id and s.invoice_no~'[0-9]+$';
 elsif tg_table_name='purchase_invoices' then
  v_kind:='purchases';
  perform pg_advisory_xact_lock(hashtextextended(new.business_id::text||':invoice:'||v_kind,0));
  select coalesce(max((substring(p.invoice_no from '([0-9]+)$'))::bigint),0)+1 into v_next
  from public.purchase_invoices p where p.business_id=new.business_id and p.invoice_no~'[0-9]+$';
 else raise exception 'Unsupported invoice table'; end if;
 new.invoice_no:=v_next::text;
 return new;
end
$function$;

alter function public.guard_product_average_cost() set search_path='';
commit;
