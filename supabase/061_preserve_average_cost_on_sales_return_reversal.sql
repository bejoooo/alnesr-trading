-- Preserve and restore weighted average cost when a good customer return is cancelled.
ALTER TABLE public.stock_movements ADD COLUMN average_cost_before numeric(14,4);

CREATE OR REPLACE FUNCTION public.apply_customer_return_average_cost()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare old_average numeric(14,4); total_quantity numeric(14,3); old_quantity numeric(14,3); new_average numeric(14,2);
begin
  if new.movement_type <> 'customer_return_good' then return new; end if;
  if new.quantity_delta <= 0 or new.unit_cost is null or new.unit_cost < 0 then
    raise exception 'Invalid good customer return stock movement cost or quantity';
  end if;
  select p.average_cost into old_average from public.products p
  where p.id=new.product_id and p.business_id=new.business_id for update;
  if not found then raise exception 'Product for customer return movement was not found'; end if;
  select coalesce(sum(sm.quantity_delta),0) into total_quantity
  from public.stock_movements sm where sm.business_id=new.business_id and sm.product_id=new.product_id;
  old_quantity:=total_quantity-new.quantity_delta;
  if old_quantity<0 or total_quantity<=0 then raise exception 'Invalid stock balance while applying customer return'; end if;
  new_average:=round(((old_quantity*old_average)+(new.quantity_delta*new.unit_cost))/total_quantity,2);
  update public.stock_movements set average_cost_before=old_average where id=new.id and business_id=new.business_id;
  update public.products set average_cost=new_average,updated_at=now()
  where id=new.product_id and business_id=new.business_id;
  return new;
end;
$function$
;

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
$function$
;
