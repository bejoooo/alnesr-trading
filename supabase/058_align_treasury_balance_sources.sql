-- Align every non-cash balance check with the same ledger composition used by the UI.
-- Balance = payments + treasury transfers + unlinked manual cash_transactions.

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
$function$
;

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
$function$
;

CREATE OR REPLACE FUNCTION public.record_invoice_payment(p_business_id uuid, p_invoice_type text, p_invoice_id uuid, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
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
  v_method_balance numeric(14,2);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'payments.create') then
    raise exception 'Not authorized to record payments';
  end if;
  if p_amount is null or p_amount<=0 then raise exception 'Payment must be positive'; end if;
  p_method:=lower(btrim(coalesce(p_method,'cash')));
  if p_method not in ('cash','bank_transfer','instapay','mobile_wallet','other') then
    raise exception 'Unsupported payment method';
  end if;
  if p_method='cash' and not public.has_business_permission(p_business_id,'cash.create') then
    raise exception 'Not authorized to change cash balance';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
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
  if v_direction='out' then
    if p_method='cash' then
      select coalesce(sum(case when direction='in' then amount else -amount end),0)
        into v_method_balance from public.cash_transactions where business_id=p_business_id;
    else
      select coalesce(sum(case when direction='in' then amount else -amount end),0)
        + coalesce((select sum(case when destination_method=p_method then amount when source_method=p_method then -amount else 0 end)
          from public.treasury_transfers where business_id=p_business_id),0)
        + coalesce((select sum(case when direction='in' then amount else -amount end)
          from public.cash_transactions where business_id=p_business_id and lower(account_method)=p_method
           and payment_id is null and treasury_transfer_id is null),0)
        into v_method_balance
      from public.payments where business_id=p_business_id and lower(method)=p_method;
    end if;
    if coalesce(v_method_balance,0)<p_amount then
      raise exception 'Insufficient % balance for this supplier payment. Available: %, requested: %',p_method,coalesce(v_method_balance,0),p_amount;
    end if;
  end if;
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
    if v_direction='out' and coalesce((select sum(case when direction='in' then amount else -amount end) from public.cash_transactions where business_id=p_business_id),0) < p_amount then
      raise exception 'Insufficient cash balance for this supplier payment';
    end if;
    insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,payment_id)
    values(p_business_id,coalesce(p_payment_date,current_date),v_direction,
      case when p_invoice_type='sale' then 'sale_payment' else 'purchase_payment' end,
      p_amount,v_party_id,p_invoice_id,'دفعة فاتورة',p_notes,auth.uid(),v_payment_id);
  end if;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'payment','invoice',p_invoice_id,
    jsonb_build_object('amount',p_amount,'method',p_method,'invoice_type',p_invoice_type));
  return v_payment_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_standalone_party_payment(p_business_id uuid, p_party_id uuid, p_account_type text, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_party public.parties%rowtype;
 v_direction text;
 v_payment_id uuid;
 v_cash_balance numeric(14,2);
 v_method_balance numeric(14,2);
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'payments.create') then
  raise exception 'Not authorized to record payments';
 end if;
 if p_account_type is null or p_account_type not in ('customer','supplier') then
  raise exception 'Choose whether this payment belongs to the customer or supplier account';
 end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment must be positive'; end if;
 p_method:=lower(btrim(coalesce(p_method,'cash')));
 if p_method not in ('cash','bank_transfer','instapay','mobile_wallet','other') then
  raise exception 'Unsupported payment method';
 end if;
 if p_account_type='customer' then
  if not public.has_business_permission(p_business_id,'sales.view') then raise exception 'Not authorized to access customer accounts'; end if;
  v_direction:='in';
 else
  if not public.has_business_permission(p_business_id,'purchases.view') then raise exception 'Not authorized to access supplier accounts'; end if;
  v_direction:='out';
 end if;
 select * into v_party from public.parties
 where id=p_party_id and business_id=p_business_id for update;
 if not found then raise exception 'Party not found in this business'; end if;
 if not v_party.is_active then raise exception 'Cannot record a payment for an archived account'; end if;
 if p_account_type='customer' and v_party.kind not in ('customer','both') then
  raise exception 'This account is not configured as a customer';
 end if;
 if p_account_type='supplier' and v_party.kind not in ('supplier','both') then
  raise exception 'This account is not configured as a supplier';
 end if;
 if p_method='cash' and not public.has_business_permission(p_business_id,'cash.create') then
  raise exception 'Not authorized to change cash balance';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 if v_direction='out' then
  if p_method='cash' then
   select coalesce(sum(case when direction='in' then amount else -amount end),0)
    into v_method_balance from public.cash_transactions where business_id=p_business_id;
  else
   select coalesce(sum(case when direction='in' then amount else -amount end),0)
    + coalesce((select sum(case when destination_method=p_method then amount when source_method=p_method then -amount else 0 end)
      from public.treasury_transfers where business_id=p_business_id),0)
    + coalesce((select sum(case when direction='in' then amount else -amount end)
      from public.cash_transactions where business_id=p_business_id and lower(account_method)=p_method
       and payment_id is null and treasury_transfer_id is null),0)
    into v_method_balance
   from public.payments where business_id=p_business_id and lower(method)=p_method;
  end if;
  if coalesce(v_method_balance,0)<p_amount then
   raise exception 'Insufficient % balance for this supplier payment. Available: %, requested: %',p_method,coalesce(v_method_balance,0),p_amount;
  end if;
 end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by)
 values(p_business_id,p_party_id,null,p_account_type,v_direction,p_amount,coalesce(p_payment_date,current_date),p_method,
  nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),auth.uid())
 returning id into v_payment_id;
 if p_method='cash' then
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,payment_id)
  values(p_business_id,coalesce(p_payment_date,current_date),v_direction,'other',p_amount,p_party_id,null,
   case when p_account_type='customer' then 'تحصيل مستقل من عميل' else 'سداد مستقل لمورد' end,
   nullif(btrim(p_notes),''),auth.uid(),v_payment_id);
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'standalone_payment','payment',v_payment_id,
  jsonb_build_object('party_id',p_party_id,'account_type',p_account_type,'direction',v_direction,'amount',p_amount,'method',p_method));
 return v_payment_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.post_purchase_with_method(p_business_id uuid, p_invoice_no text, p_supplier_id uuid, p_invoice_date date, p_items jsonb, p_supplier_discount numeric DEFAULT 0, p_paid_amount numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_method text DEFAULT 'cash'::text, p_use_supplier_credit boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_invoice_id uuid; v_generated_code text; v_item jsonb; v_product public.products%rowtype; v_payment_id uuid;
 v_qty numeric(14,3); v_price numeric(14,2); v_subtotal numeric(14,2):=0;
 v_discount numeric(14,2); v_total numeric(14,2); v_line_gross numeric(14,2);
 v_line_discount numeric(14,2); v_discount_used numeric(14,2):=0;
 v_item_count integer; v_i integer:=0; v_on_hand numeric(14,3);
 v_new_avg numeric(14,2); v_supplier_name text; v_supplier_credit numeric(14,2):=0;
 v_method text:=lower(trim(coalesce(p_method,'cash')));
 v_paid numeric(14,2):=round(coalesce(p_paid_amount,0),2);
 v_available numeric(14,2):=0;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'purchases.create') then
  raise exception 'Not authorized to create purchases';
 end if;
 if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then
  raise exception 'Choose a supported treasury account';
 end if;
 v_generated_code:=public.next_operation_code(p_business_id,'purchase_invoice');
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
  raise exception 'At least one purchase item is required';
 end if;
 if coalesce(p_supplier_discount,0)<0 or v_paid<0 then
  raise exception 'Discount and paid amount cannot be negative';
 end if;
 if v_paid>0 then
  if v_method='cash' then
   if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to record the cash payment'; end if;
  else
   if not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to record this payment method'; end if;
  end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 perform 1 from public.products p
 where p.business_id=p_business_id
  and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)
 order by p.id for update;
 if p_supplier_id is not null then
  select name into v_supplier_name from public.parties
  where id=p_supplier_id and business_id=p_business_id and kind in ('supplier','both') and is_active;
  if not found then raise exception 'Supplier does not belong to this business or is inactive'; end if;
 end if;
 select count(*),coalesce(sum(round((x->>'quantity')::numeric*(x->>'unit_price')::numeric,2)),0)
 into v_item_count,v_subtotal from jsonb_array_elements(p_items) x;
 if v_item_count=0 then raise exception 'Empty purchase'; end if;
 v_discount:=round(coalesce(p_supplier_discount,0),2);
 if v_discount>v_subtotal then raise exception 'Supplier discount exceeds subtotal'; end if;
 v_total:=round(v_subtotal-v_discount,2);
 if p_supplier_id is not null and coalesce(p_use_supplier_credit,false) then
  select greatest(0,-coalesce(supplier_net_balance,0)) into v_supplier_credit
  from public.party_account_balances where business_id=p_business_id and party_id=p_supplier_id;
  v_supplier_credit:=least(coalesce(v_supplier_credit,0),greatest(0,v_total-v_paid));
 end if;
 if v_paid>v_total then raise exception 'Paid amount exceeds invoice total'; end if;
 if v_paid>0 then
  if v_method='cash' then
   select coalesce(balance,0) into v_available from public.cash_balances where business_id=p_business_id;
   v_available:=coalesce(v_available,0);
  else
   select
    coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
     from public.payments p where p.business_id=p_business_id and lower(p.method)=v_method),0)
    +coalesce((select sum(case when t.destination_method=v_method then t.amount when t.source_method=v_method then -t.amount else 0 end)
     from public.treasury_transfers t where t.business_id=p_business_id),0)
    +coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
     from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_method) and c.payment_id is null and c.treasury_transfer_id is null),0)
   into v_available;
  end if;
  if coalesce(v_available,0)<v_paid then
   raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0);
  end if;
 end if;
 insert into public.purchase_invoices(
  business_id,invoice_no,supplier_id,supplier_name_snapshot,invoice_date,
  subtotal,supplier_discount,total,paid_total,supplier_credit_applied_total,due_total,status,notes,created_by
 ) values (
  p_business_id,v_generated_code,p_supplier_id,v_supplier_name,coalesce(p_invoice_date,current_date),
  v_subtotal,v_discount,v_total,v_paid,v_supplier_credit,v_total-v_paid-v_supplier_credit,
  case when v_paid+v_supplier_credit=v_total then 'paid' when v_paid+v_supplier_credit=0 then 'posted' else 'partially_paid' end,
  p_notes,auth.uid()
 ) returning id into v_invoice_id;
 for v_item in select value from jsonb_array_elements(p_items)
 loop
  v_i:=v_i+1;
  if not (v_item ? 'product_id') then raise exception 'Missing product_id'; end if;
  v_qty:=(v_item->>'quantity')::numeric; v_price:=(v_item->>'unit_price')::numeric;
  if v_qty<=0 or v_price<0 then raise exception 'Invalid purchase quantity or price'; end if;
  select * into v_product from public.products
  where id=(v_item->>'product_id')::uuid and business_id=p_business_id and is_active for update;
  if not found then raise exception 'Product does not belong to this business or is inactive'; end if;
  insert into public.purchase_invoice_cost_snapshots(business_id,invoice_id,product_id,average_cost_before)
  values(p_business_id,v_invoice_id,v_product.id,v_product.average_cost)
  on conflict(invoice_id,product_id) do nothing;
  v_line_gross:=round(v_qty*v_price,2);
  if v_i=v_item_count then v_line_discount:=v_discount-v_discount_used;
  else
   v_line_discount:=case when v_subtotal=0 then 0 else least(round(v_discount*v_line_gross/v_subtotal,2),v_discount-v_discount_used) end;
   v_discount_used:=v_discount_used+v_line_discount;
  end if;
  insert into public.purchase_items(
   business_id,invoice_id,product_id,product_name_snapshot,quantity,unit_price,
   allocated_discount,net_line_total,unit_landed_cost
  ) values (
   p_business_id,v_invoice_id,v_product.id,v_product.name,v_qty,v_price,
   v_line_discount,v_line_gross-v_line_discount,
   case when v_qty=0 then 0 else (v_line_gross-v_line_discount)/v_qty end
  );
  select coalesce(sum(quantity_delta),0) into v_on_hand
  from public.stock_movements where business_id=p_business_id and product_id=v_product.id;
  v_new_avg:=case when v_on_hand+v_qty<=0 then v_product.average_cost
   else round(((v_on_hand*v_product.average_cost)+((v_line_gross-v_line_discount)/v_qty*v_qty))/(v_on_hand+v_qty),2) end;
  update public.products set average_cost=v_new_avg,updated_at=now() where id=v_product.id;
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,created_by
  ) values (
   p_business_id,v_product.id,coalesce(p_invoice_date,current_date),'purchase',v_qty,
   (v_line_gross-v_line_discount)/v_qty,'purchase',v_invoice_id,auth.uid()
  );
 end loop;
 if v_paid>0 then
  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by)
  values(p_business_id,p_supplier_id,v_invoice_id,'out',v_paid,coalesce(p_invoice_date,current_date),v_method,
   'دفعة عند إنشاء فاتورة مشتريات',auth.uid()) returning id into v_payment_id;
  if v_method='cash' then
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,created_by,account_method,payment_id)
   values(p_business_id,coalesce(p_invoice_date,current_date),'out','purchase_payment',v_paid,p_supplier_id,v_invoice_id,
    'سداد عند إنشاء فاتورة مشتريات',auth.uid(),'cash',v_payment_id);
  end if;
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'post','purchase_invoice',v_invoice_id,
  jsonb_build_object('invoice_no',v_generated_code,'total',v_total,'paid',v_paid,'method',v_method));
 return v_invoice_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_expense(p_business_id uuid, p_name text, p_amount numeric, p_expense_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text, p_method text DEFAULT 'cash'::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_id uuid;
 v_cash_id uuid;
 v_method text := lower(trim(coalesce(p_method,'cash')));
 v_amount numeric(14,2) := round(p_amount,2);
 v_available numeric(14,2);
begin
 if auth.uid() is null
    or not public.has_business_permission(p_business_id,'expenses.create')
    or not public.has_business_permission(p_business_id,'cash.withdraw') then
   raise exception 'Not authorized to record expense';
 end if;
 if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then
   raise exception 'Choose a supported payment method';
 end if;
 if coalesce(trim(p_name),'')='' or p_amount is null or p_amount<=0 or v_amount<=0 then
   raise exception 'Expense name and positive amount are required';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

 if v_method='cash' then
   select coalesce(balance,0) into v_available
   from public.cash_balances where business_id=p_business_id;
   v_available:=coalesce(v_available,0);
 else
   select
     coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
       from public.payments p where p.business_id=p_business_id and lower(p.method)=v_method),0)
     + coalesce((select sum(case when t.destination_method=v_method then t.amount
                                 when t.source_method=v_method then -t.amount else 0 end)
       from public.treasury_transfers t where t.business_id=p_business_id),0)
     + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
       from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_method) and c.payment_id is null and c.treasury_transfer_id is null),0)
   into v_available;
 end if;
 if coalesce(v_available,0)<v_amount then
   raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0);
 end if;

 insert into public.expenses(business_id,name,amount,expense_date,notes,created_by)
 values(p_business_id,trim(p_name),v_amount,coalesce(p_expense_date,current_date),p_notes,auth.uid())
 returning id into v_id;

 insert into public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,account_method
 ) values(
   p_business_id,coalesce(p_expense_date,current_date),'out','expense',v_amount,
   trim(p_name),p_notes,auth.uid(),v_method
 ) returning id into v_cash_id;

 update public.expenses set cash_transaction_id=v_cash_id
 where id=v_id and business_id=p_business_id;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'expense','expense',v_id,
   jsonb_build_object('amount',v_amount,'name',trim(p_name),'method',v_method,'cash_transaction_id',v_cash_id));
 return v_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.record_treasury_withdrawal(p_business_id uuid, p_method text, p_amount numeric, p_reason text, p_transaction_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_method text:=lower(trim(coalesce(p_method,''))); v_id uuid; v_available numeric(14,2); v_amount numeric(14,2):=round(p_amount,2);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to withdraw treasury funds'; end if;
  if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then raise exception 'Choose a supported treasury account'; end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 or coalesce(trim(p_reason),'')='' then raise exception 'Positive amount and withdrawal reason are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  if v_method='cash' then
    select coalesce(balance,0) into v_available from public.cash_balances where business_id=p_business_id;
    v_available:=coalesce(v_available,0);
  else
    select coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end) from public.payments p where p.business_id=p_business_id and lower(p.method)=v_method),0)
      +coalesce((select sum(case when t.destination_method=v_method then t.amount when t.source_method=v_method then -t.amount else 0 end) from public.treasury_transfers t where t.business_id=p_business_id),0)
      +coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end) from public.cash_transactions c where c.business_id=p_business_id and lower(c.account_method)=lower(v_method) and c.payment_id is null and c.treasury_transfer_id is null),0)
    into v_available;
  end if;
  if coalesce(v_available,0)<v_amount then raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0); end if;
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,account_method)
  values(p_business_id,coalesce(p_transaction_date,current_date),'out','other',v_amount,trim(p_reason),nullif(trim(coalesce(p_notes,'')),''),auth.uid(),v_method) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'treasury_withdrawal','cash_transaction',v_id,jsonb_build_object('amount',v_amount,'reason',trim(p_reason),'method',v_method));
  return v_id;
end; $function$
;

CREATE OR REPLACE FUNCTION public.pay_customer_credit(p_business_id uuid, p_customer_id uuid, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_party public.parties%rowtype; v_method text:=lower(trim(coalesce(p_method,'cash'))); v_available numeric(14,2):=0; v_method_balance numeric(14,2):=0; v_payment_id uuid; v_row record; v_remaining numeric(14,2); v_take numeric(14,2);
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 if v_method='cash' then
  if not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to withdraw cash'; end if;
 else
  if not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to pay through this account'; end if;
 end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payout amount must be positive'; end if;
 if v_method not in ('cash','bank_transfer','instapay','mobile_wallet','other') then raise exception 'Unsupported payment method'; end if;
 if v_method='cash' and not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to withdraw cash'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_party from public.parties where id=p_customer_id and business_id=p_business_id for update;
 if not found or not v_party.is_active or v_party.kind not in ('customer','both') then raise exception 'Active customer account not found'; end if;
 perform 1 from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id for update;
 select coalesce(sum(amount),0) into v_available from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id;
 if p_amount>v_available then raise exception 'Payout exceeds available customer credit. Available: %',v_available; end if;
 if v_method='cash' then select coalesce(balance,0) into v_method_balance from public.cash_balances where business_id=p_business_id;
 else select coalesce((select sum(case when direction='in' then amount else -amount end) from public.payments where business_id=p_business_id and lower(method)=v_method),0)+coalesce((select sum(case when destination_method=v_method then amount when source_method=v_method then -amount else 0 end) from public.treasury_transfers where business_id=p_business_id),0)+coalesce((select sum(case when direction='in' then amount else -amount end) from public.cash_transactions where business_id=p_business_id and lower(account_method)=lower(v_method) and payment_id is null and treasury_transfer_id is null),0) into v_method_balance; end if;
 if v_method_balance<p_amount then raise exception 'Insufficient balance in selected account. Available: %',v_method_balance; end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by) values(p_business_id,p_customer_id,null,'customer','out',p_amount,coalesce(p_payment_date,current_date),v_method,nullif(btrim(p_reference),''),coalesce(nullif(btrim(p_notes),''),'سداد رصيد دائن لعميل'),auth.uid()) returning id into v_payment_id;
 v_remaining:=p_amount;
 for v_row in select source_return_id,sum(amount) available from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id and source_return_id is not null group by source_return_id having sum(amount)>0 order by min(created_at),source_return_id loop
  exit when v_remaining<=0; v_take:=least(v_remaining,v_row.available);
  insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,event_type,amount,payment_id,created_by) values(p_business_id,p_customer_id,v_row.source_return_id,'payout',-v_take,v_payment_id,auth.uid()); v_remaining:=v_remaining-v_take;
 end loop;
 if v_remaining>0 then raise exception 'Customer credit changed while processing payout; retry'; end if;
 if v_method='cash' then insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,account_method,payment_id) values(p_business_id,coalesce(p_payment_date,current_date),'out','other',p_amount,p_customer_id,null,'سداد رصيد دائن لعميل',p_notes,auth.uid(),'cash',v_payment_id); end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details) values(p_business_id,auth.uid(),'customer_credit_payout','payment',v_payment_id,jsonb_build_object('customer_id',p_customer_id,'amount',p_amount,'method',v_method)); return v_payment_id;
end;$function$
;

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
$function$
;

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
$function$
;

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
end; $function$
;

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
$function$
;
