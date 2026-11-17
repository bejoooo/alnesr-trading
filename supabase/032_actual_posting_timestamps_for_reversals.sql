
-- Actual posting timestamps make "later movement" checks reliable under concurrent requests.
alter table public.stock_movements add column if not exists posted_at timestamptz;
update public.stock_movements set posted_at=created_at where posted_at is null;
alter table public.stock_movements alter column posted_at set default clock_timestamp();
alter table public.stock_movements alter column posted_at set not null;

alter table public.sales_returns add column if not exists posted_at timestamptz;
update public.sales_returns set posted_at=created_at where posted_at is null;
alter table public.sales_returns alter column posted_at set default clock_timestamp();
alter table public.sales_returns alter column posted_at set not null;

alter table public.payments add column if not exists posted_at timestamptz;
update public.payments set posted_at=created_at where posted_at is null;
alter table public.payments alter column posted_at set default clock_timestamp();
alter table public.payments alter column posted_at set not null;

create index if not exists stock_movements_business_product_posted_idx
 on public.stock_movements(business_id,product_id,posted_at);
create index if not exists sales_returns_business_invoice_posted_idx
 on public.sales_returns(business_id,sales_invoice_id,posted_at);
create index if not exists payments_business_invoice_posted_idx
 on public.payments(business_id,invoice_id,posted_at);

CREATE OR REPLACE FUNCTION public.owner_void_invoice(p_business_id uuid, p_invoice_type text, p_invoice_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
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
  if exists(select 1 from public.sales_returns
    where business_id=p_business_id and sales_invoice_id=p_invoice_id and status<>'void') then
   raise exception 'Cannot cancel an invoice with active returns; cancel the returns first';
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
    and direction='in' and lower(method)='cash' and sales_return_id is null and reversal_of_payment_id is null;
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='sale_payment' and direction='in'
    and reversal_of_transaction_id is null;
 else
  select coalesce(sum(amount),0) into v_payment_cash
  from public.payments
  where business_id=p_business_id and invoice_id=p_invoice_id
    and direction='out' and lower(method)='cash' and sales_return_id is null and reversal_of_payment_id is null;
  select coalesce(sum(amount),0) into v_cash_ledger
  from public.cash_transactions
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type='purchase_payment' and direction='out'
    and reversal_of_transaction_id is null;
 end if;
 if v_payment_cash<>v_cash_ledger then
  raise exception 'Cash payment history does not reconcile with the cash ledger; invoice was not changed';
 end if;
 v_cash_total:=v_cash_ledger;

 if p_invoice_type='sale' then
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_cash_balance from public.cash_transactions where business_id=p_business_id;
  if v_cash_total>v_cash_balance then
   raise exception 'Cash balance is insufficient to reverse cash receipts. Record a cash deposit first.';
  end if;
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
  where business_id=p_business_id and invoice_id=p_invoice_id
    and transaction_type=case when p_invoice_type='sale' then 'sale_payment' else 'purchase_payment' end
    and reversal_of_transaction_id is null
  order by created_at,id for update
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
$function$
;
CREATE OR REPLACE FUNCTION public.owner_reverse_stock_adjustment(p_business_id uuid, p_movement_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_m record; v_balance numeric(14,3); v_avg numeric(14,2); v_new_id uuid:=gen_random_uuid();
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members where business_id=p_business_id
  and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can reverse stock adjustments'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_m from public.stock_movements
 where id=p_movement_id and business_id=p_business_id for update;
 if not found or v_m.source_type<>'manual_adjustment'
   or v_m.movement_type not in ('adjustment_in','adjustment_out') then
  raise exception 'Stock adjustment not found or not eligible for reversal';
 end if;
 if v_m.reversal_of_movement_id is not null or exists(
  select 1 from public.stock_movements where reversal_of_movement_id=v_m.id
 ) then raise exception 'This stock adjustment has already been reversed'; end if;
 if exists(
  select 1 from public.stock_movements m
  where m.business_id=p_business_id and m.product_id=v_m.product_id
   and m.posted_at>v_m.posted_at and m.id<>v_m.id
 ) then raise exception 'Later stock movements exist for this product; this adjustment cannot be reversed safely'; end if;
 select coalesce(sum(quantity_delta),0) into v_balance from public.stock_movements
 where business_id=p_business_id and product_id=v_m.product_id;
 if v_balance-v_m.quantity_delta<0 then
  raise exception 'Current stock is insufficient to reverse this adjustment';
 end if;
 if v_m.movement_type='adjustment_in' then
  select average_cost_before into v_avg from public.stock_adjustment_cost_snapshots
  where business_id=p_business_id and movement_id=v_m.id and product_id=v_m.product_id;
  if not found then raise exception 'This older stock increase has no cost snapshot and cannot be safely reversed'; end if;
 end if;
 insert into public.stock_movements(
  id,business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,notes,created_by,reversal_of_movement_id
 ) values(
  v_new_id,p_business_id,v_m.product_id,current_date,
  case when v_m.quantity_delta>0 then 'adjustment_out' else 'adjustment_in' end,
  -v_m.quantity_delta,v_m.unit_cost,'adjustment_reversal',v_m.id,
  'عكس تسوية مخزون: '||coalesce(v_m.notes,''),auth.uid(),v_m.id
 );
 if v_m.movement_type='adjustment_in' then
  update public.products set average_cost=v_avg,updated_at=now()
  where id=v_m.product_id and business_id=p_business_id;
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'reverse','stock_movement',v_m.id,
 jsonb_build_object('reversal_id',v_new_id,'quantity_delta',-v_m.quantity_delta));
 return v_new_id;
end;
$function$
;
CREATE OR REPLACE FUNCTION public.owner_remove_sales_return(p_business_id uuid, p_return_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
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
   and direction='out' and method='cash';
 if exists(select 1 from public.cash_transactions where business_id=p_business_id and invoice_id=v_invoice.id and transaction_type='customer_refund' and direction='out' and sales_return_id is null) then raise exception 'Legacy cash refunds without a return link exist for this invoice; this return cannot be cancelled safely'; end if;
 if exists(select 1 from public.payments where business_id=p_business_id and invoice_id=v_invoice.id and direction='out' and method='cash' and sales_return_id is null) then raise exception 'Legacy cash refund payment without a return link exists; this return cannot be cancelled safely'; end if;
 if v_payment_count>1 then raise exception 'Multiple cash refund payment records are linked to this return'; end if;

 select count(*) into v_cash_count from public.cash_transactions
 where business_id=p_business_id and sales_return_id=p_return_id
   and transaction_type='customer_refund' and direction='out';
 if v_cash_count<>v_payment_count then
  raise exception 'The cash refund ledger does not match the return payment ledger; no changes were made';
 end if;

 if v_payment_count=1 then
  select * into v_refund_payment from public.payments
  where business_id=p_business_id and sales_return_id=p_return_id
   and direction='out' and method='cash' for update;
  select * into v_cash_tx from public.cash_transactions
  where business_id=p_business_id and sales_return_id=p_return_id
   and transaction_type='customer_refund' and direction='out' for update;
  if v_refund_payment.amount<>v_cash_tx.amount
     or v_refund_payment.invoice_id<>v_invoice.id
     or v_cash_tx.invoice_id<>v_invoice.id then
   raise exception 'The linked cash refund amount or invoice does not match; no changes were made';
  end if;
  if exists(select 1 from public.cash_transactions where reversal_of_transaction_id=v_cash_tx.id)
     or exists(select 1 from public.payments where reversal_of_payment_id=v_refund_payment.id) then
   raise exception 'This return refund has already been reversed';
  end if;
  v_cash_refund:=v_refund_payment.amount;
  insert into public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id,sales_return_id
  ) values(
   p_business_id,current_date,'in','deposit',v_cash_refund,v_invoice.customer_id,v_invoice.id,
   'عكس رد نقدي لمرتجع ملغى','عكس حركة رد المرتجع رقم '||v_return.return_no,
   auth.uid(),v_cash_tx.id,p_return_id
  ) returning id into v_reversal;
  insert into public.payments(
   business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,notes,
   created_by,sales_return_id,reversal_of_payment_id
  ) values(
   p_business_id,v_refund_payment.party_id,v_invoice.id,'in',v_cash_refund,current_date,
   'cash','عكس رد المرتجع '||v_return.return_no,
   'عكس دفعة رد نقدي لمرتجع ملغى',auth.uid(),p_return_id,v_refund_payment.id
  ) returning id into v_payment_reversal;
 end if;

 v_credit_applied:=v_return.refund_total-v_cash_refund;
 if v_credit_applied<0 then raise exception 'Return refund allocation is inconsistent'; end if;

 for v_item in
  select sri.sales_item_id,sum(sri.quantity) as return_qty,si.returned_quantity
  from public.sales_return_items sri
  join public.sales_items si on si.id=sri.sales_item_id and si.business_id=sri.business_id
  where sri.business_id=p_business_id and sri.return_id=p_return_id
  group by sri.sales_item_id,si.returned_quantity
  for update of si
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
   where business_id=p_business_id and source_type='sales_return' and source_id=p_return_id
   group by product_id
  ) movements using(product_id)
  where coalesce(good_items.qty,0)<>coalesce(movements.qty,0)
 ) then raise exception 'Returned stock movements do not match good-condition return items'; end if;

 for v_stock in
  select * from public.stock_movements
  where business_id=p_business_id and source_type='sales_return' and source_id=p_return_id
  for update
 loop
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
   source_type,source_id,notes,created_by,reversal_of_movement_id
  ) values(
   p_business_id,v_stock.product_id,current_date,'adjustment_out',-v_stock.quantity_delta,
   v_stock.unit_cost,'sales_return_reversal',v_stock.id,'عكس مرتجع مبيعات ملغى',auth.uid(),v_stock.id
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
      when due_total+v_credit_applied=0 then 'paid'
      when paid_total+v_cash_refund>0 then 'partially_paid'
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
$function$
;
CREATE OR REPLACE FUNCTION public.owner_remove_cash_transaction(p_business_id uuid, p_transaction_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tx record; v_balance numeric(14,2); v_reversal_id uuid;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can reverse cash transactions'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_tx from public.cash_transactions
 where id=p_transaction_id and business_id=p_business_id for update;
 if not found then raise exception 'Cash transaction not found'; end if;
 if v_tx.reversal_of_transaction_id is not null then
  raise exception 'A reversal entry cannot itself be reversed here';
 end if;
 if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_tx.id) then
  raise exception 'This cash movement has already been reversed';
 end if;
 if v_tx.invoice_id is not null or v_tx.party_id is not null
    or v_tx.sales_return_id is not null
    or exists(select 1 from public.expenses e where e.cash_transaction_id=v_tx.id)
    or v_tx.transaction_type not in ('deposit','other') then
  raise exception 'This cash movement is linked to an invoice, expense, refund, or opening balance and cannot be removed here';
 end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
 into v_balance from public.cash_transactions where business_id=p_business_id;
 if v_tx.direction='in' and v_balance<v_tx.amount then
  raise exception 'Cash balance is insufficient to reverse this deposit';
 end if;
 insert into public.cash_transactions(
  business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,reversal_of_transaction_id
 ) values(
  p_business_id,current_date,case when v_tx.direction='in' then 'out' else 'in' end,'other',v_tx.amount,
  'عكس حركة خزنة: '||coalesce(v_tx.reason,'بدون بيان'),
  'عكس الحركة الأصلية رقم '||p_transaction_id,auth.uid(),v_tx.id
 ) returning id into v_reversal_id;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'remove_reversed','cash_transaction',p_transaction_id,
  jsonb_build_object('amount',v_tx.amount,'original_direction',v_tx.direction,'reversal_id',v_reversal_id));
 return 'reversed';
end;
$function$
;
CREATE OR REPLACE FUNCTION public.owner_remove_expense(p_business_id uuid, p_expense_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_exp record; v_cash record; v_balance numeric(14,2); v_reversal_id uuid;
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
 ) then raise exception 'Only the active business owner can remove expenses'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_exp from public.expenses
 where id=p_expense_id and business_id=p_business_id for update;
 if not found then raise exception 'Expense not found'; end if;
 if v_exp.cash_transaction_id is null then
  raise exception 'This older expense has no verified cash link and cannot be safely removed';
 end if;
 select * into v_cash from public.cash_transactions
 where id=v_exp.cash_transaction_id and business_id=p_business_id for update;
 if not found or v_cash.transaction_type<>'expense' or v_cash.direction<>'out'
    or v_cash.amount<>v_exp.amount
    or v_cash.transaction_date<>v_exp.expense_date
    or v_cash.invoice_id is not null or v_cash.party_id is not null
    or v_cash.sales_return_id is not null
    or v_cash.reversal_of_transaction_id is not null then
  raise exception 'The linked cash movement does not match this expense; no changes were made';
 end if;
 if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_cash.id) then
  raise exception 'This expense cash movement has already been reversed';
 end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0)
 into v_balance from public.cash_transactions where business_id=p_business_id;
 insert into public.cash_transactions(
  business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,reversal_of_transaction_id
 ) values(
  p_business_id,current_date,'in','deposit',v_exp.amount,'عكس حذف مصروف: '||v_exp.name,
  'عكس حركة المصروف المحذوف رقم '||p_expense_id,auth.uid(),v_cash.id
 ) returning id into v_reversal_id;
 delete from public.expenses where id=p_expense_id and business_id=p_business_id;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'remove_reversed','expense',p_expense_id,
  jsonb_build_object('amount',v_exp.amount,'cash_transaction_id',v_cash.id,'reversal_id',v_reversal_id));
 return 'deleted_reversed';
end;
$function$
;
