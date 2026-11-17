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
  perform 1 from public.products p
  join public.sales_items i on i.business_id=p.business_id and i.product_id=p.id
  where p.business_id=p_business_id and i.invoice_id=p_invoice_id
  order by p.id for update of p;
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
$function$
;

CREATE OR REPLACE FUNCTION public.record_invoice_payment(p_business_id uuid, p_invoice_type text, p_invoice_id uuid, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_party_id uuid;
  v_due numeric(14,2);
  v_total_paid numeric(14,2);
  v_total numeric(14,2);
  v_payment_id uuid;
  v_direction text;
  v_permission text;
  v_status text;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'payments.create') then
    raise exception 'Not authorized to record payments';
  end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment must be positive'; end if;
  p_method:=lower(btrim(coalesce(p_method,'cash')));
  if p_method not in ('cash','bank_transfer','instapay','other') then
    raise exception 'Unsupported payment method';
  end if;
  if p_method='cash' then
    if not public.has_business_permission(p_business_id,'cash.create') then
      raise exception 'Not authorized to change cash balance';
    end if;
  end if;

  if p_invoice_type='sale' then
    v_direction:='in'; v_permission:='sales.view';
    select customer_id,due_total,total,paid_total,status into v_party_id,v_due,v_total,v_total_paid,v_status
    from public.sales_invoices where id=p_invoice_id and business_id=p_business_id for update;
  elsif p_invoice_type='purchase' then
    v_direction:='out'; v_permission:='purchases.view';
    select supplier_id,due_total,total,paid_total,status into v_party_id,v_due,v_total,v_total_paid,v_status
    from public.purchase_invoices where id=p_invoice_id and business_id=p_business_id for update;
  else
    raise exception 'Invoice type must be sale or purchase';
  end if;
  if not found then raise exception 'Invoice not found in this business'; end if;
  if v_status='void' then raise exception 'Cannot record a payment against a cancelled invoice'; end if;
  if not public.has_business_permission(p_business_id,v_permission) then raise exception 'Not authorized'; end if;
  if p_amount>v_due then raise exception 'Payment exceeds outstanding amount'; end if;

  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,reference,notes,created_by)
  values(p_business_id,v_party_id,p_invoice_id,v_direction,p_amount,coalesce(p_payment_date,current_date),p_method,p_reference,p_notes,auth.uid())
  returning id into v_payment_id;

  if p_invoice_type='sale' then
    update public.sales_invoices set paid_total=paid_total+p_amount,due_total=due_total-p_amount where id=p_invoice_id;
  else
    update public.purchase_invoices set paid_total=paid_total+p_amount,due_total=due_total-p_amount,
      status=case when due_total-p_amount=0 then 'paid' else 'partially_paid' end
    where id=p_invoice_id;
  end if;

  if lower(p_method)='cash' then
    perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
    if v_direction='out' and coalesce((select sum(case when direction='in' then amount else -amount end) from public.cash_transactions where business_id=p_business_id),0) < p_amount then
      raise exception 'Insufficient cash balance for this supplier payment';
    end if;
    insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by)
    values(p_business_id,coalesce(p_payment_date,current_date),v_direction,
      case when p_invoice_type='sale' then 'sale_payment' else 'purchase_payment' end,
      p_amount,v_party_id,p_invoice_id,'دفعة فاتورة',p_notes,auth.uid());
  end if;

  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'payment','invoice',p_invoice_id,
    jsonb_build_object('amount',p_amount,'method',p_method,'invoice_type',p_invoice_type));
  return v_payment_id;
end;
$function$
;
