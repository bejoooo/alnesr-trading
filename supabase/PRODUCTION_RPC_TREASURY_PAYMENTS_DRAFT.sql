-- DRAFT ONLY — treasury, payment, expense, and opening-balance RPC batch
-- Definitions are extracted from the current Test schema after catalog review.
-- Apply only after all schema, helper/trigger, and reporting-view stages are approved.
-- No RPC in this file is executed by this migration.

begin;
set local search_path = pg_catalog, public;

-- Fail closed until all table/view/helper dependencies are present.
do $preflight$
declare v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name) into v_missing
  from (values
    ('public.business_members'),
    ('public.parties'),
    ('public.purchase_invoices'),
    ('public.sales_invoices'),
    ('public.payments'),
    ('public.cash_transactions'),
    ('public.expenses'),
    ('public.treasury_transfers'),
    ('public.audit_log'),
    ('public.cash_balances'),
    ('public.party_account_balances')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing base tables/views for RPC batch: %',array_to_string(v_missing,', ');
  end if;

  if to_regprocedure('public.has_business_permission(uuid,text)') is null
     or to_regprocedure('public.next_operation_code(uuid,text)') is null then
    raise exception 'Missing required helper functions for RPC batch';
  end if;

  if exists (
    select 1
    from (values
      ('expenses','expense_code'),
      ('expenses','status'),
      ('expenses','cash_transaction_id'),
      ('payments','payment_code'),
      ('payments','party_account_type'),
      ('payments','purchase_return_id'),
      ('cash_transactions','transaction_code'),
      ('cash_transactions','account_method'),
      ('cash_transactions','payment_id'),
      ('cash_transactions','treasury_transfer_id'),
      ('cash_transactions','purchase_return_id'),
      ('treasury_transfers','transfer_code'),
      ('treasury_transfers','reversal_of_transfer_id')
    ) as required(table_name,column_name)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public'
        and c.table_name=required.table_name
        and c.column_name=required.column_name
    )
  ) then
    raise exception 'Missing required columns for RPC batch';
  end if;
end
$preflight$;

-- create_treasury_transfer(uuid,text,text,numeric,date,text)
CREATE OR REPLACE FUNCTION public.create_treasury_transfer(p_business_id uuid, p_source_method text, p_destination_method text, p_amount numeric, p_transfer_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_source text:=lower(trim(coalesce(p_source_method,'')));
  v_destination text:=lower(trim(coalesce(p_destination_method,'')));
  v_amount numeric(14,2):=round(p_amount,2);
  v_available numeric(14,2);
  v_transfer_id uuid;
  v_label_source text;
  v_label_destination text;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'treasury_transfer.create')
  then raise exception 'Not authorized to create treasury transfers'; end if;

  if v_source not in ('cash','instapay','bank_transfer','mobile_wallet','other')
    or v_destination not in ('cash','instapay','bank_transfer','mobile_wallet','other')
    or v_source=v_destination then
    raise exception 'Choose two different supported balance accounts';
  end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 then
    raise exception 'Transfer amount must be positive'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

  if v_source='cash' then
    select coalesce(balance,0) into v_available from public.cash_balances
    where business_id=p_business_id;
    v_available:=coalesce(v_available,0);
  else
    select
      coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
        from public.payments p where p.business_id=p_business_id and lower(p.method)=v_source),0)
      + coalesce((select sum(case
          when t.destination_method=v_source then t.amount
          when t.source_method=v_source then -t.amount else 0 end)
        from public.treasury_transfers t where t.business_id=p_business_id),0)
      + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
        from public.cash_transactions c where c.business_id=p_business_id
          and c.account_method=v_source and c.payment_id is null
          and c.treasury_transfer_id is null),0)
    into v_available;
  end if;

  if coalesce(v_available,0)<v_amount then
    raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0); end if;

  insert into public.treasury_transfers(
    business_id,transfer_date,source_method,destination_method,amount,notes,created_by
  ) values (
    p_business_id,coalesce(p_transfer_date,current_date),v_source,v_destination,
    v_amount,nullif(trim(coalesce(p_notes,'')),''),auth.uid()
  ) returning id into v_transfer_id;

  v_label_source:=case v_source when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;
  v_label_destination:=case v_destination when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;

  if v_source='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,
      created_by,treasury_transfer_id,account_method
    ) values (
      p_business_id,coalesce(p_transfer_date,current_date),'out','other',v_amount,
      'تحويل رصيد إلى '||v_label_destination,
      coalesce(nullif(trim(coalesce(p_notes,'')),''),'تحويل داخلي بين الأرصدة'),
      auth.uid(),v_transfer_id,'cash'
    );
  elsif v_destination='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,
      created_by,treasury_transfer_id,account_method
    ) values (
      p_business_id,coalesce(p_transfer_date,current_date),'in','other',v_amount,
      'تحويل رصيد من '||v_label_source,
      coalesce(nullif(trim(coalesce(p_notes,'')),''),'تحويل داخلي بين الأرصدة'),
      auth.uid(),v_transfer_id,'cash'
    );
  end if;

  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'create_treasury_transfer','treasury_transfer',v_transfer_id,
    jsonb_build_object('source_method',v_source,'destination_method',v_destination,
      'amount',v_amount,'transfer_date',coalesce(p_transfer_date,current_date)));
  return v_transfer_id;
end;
$function$;

revoke all on function public.create_treasury_transfer(uuid,text,text,numeric,date,text) from public, anon, authenticated;
grant execute on function public.create_treasury_transfer(uuid,text,text,numeric,date,text) to authenticated, service_role;

-- get_treasury_balances(uuid)
CREATE OR REPLACE FUNCTION public.get_treasury_balances(p_business_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_cash numeric(14,2) := 0;
  v_instapay numeric(14,2) := 0;
  v_bank_transfer numeric(14,2) := 0;
  v_mobile_wallet numeric(14,2) := 0;
  v_other numeric(14,2) := 0;
begin
  if auth.uid() is null
    or not public.has_business_permission(p_business_id,'treasury_transfer.view')
  then raise exception 'Not authorized to view treasury balances'; end if;

  select coalesce(cb.balance,0)::numeric(14,2) into v_cash
  from public.cash_balances cb where cb.business_id=p_business_id;
  v_cash := coalesce(v_cash,0);

  with movements as (
    select lower(p.method) method,
      case when p.direction='in' then p.amount else -p.amount end amount
    from public.payments p where p.business_id=p_business_id
    union all
    select lower(t.source_method), -t.amount
    from public.treasury_transfers t where t.business_id=p_business_id
    union all
    select lower(t.destination_method), t.amount
    from public.treasury_transfers t where t.business_id=p_business_id
    union all
    select lower(c.account_method),
      case when c.direction='in' then c.amount else -c.amount end
    from public.cash_transactions c
    where c.business_id=p_business_id and lower(c.account_method)<>'cash'
      and c.payment_id is null and c.treasury_transfer_id is null
  )
  select
    coalesce(sum(amount) filter(where method='instapay'),0),
    coalesce(sum(amount) filter(where method='bank_transfer'),0),
    coalesce(sum(amount) filter(where method='mobile_wallet'),0),
    coalesce(sum(amount) filter(where method='other'),0)
  into v_instapay,v_bank_transfer,v_mobile_wallet,v_other
  from movements;

  return jsonb_build_object(
    'cash',v_cash,'instapay',v_instapay,'bank_transfer',v_bank_transfer,
    'mobile_wallet',v_mobile_wallet,'other',v_other,
    'total',v_cash+v_instapay+v_bank_transfer+v_mobile_wallet+v_other
  );
end;
$function$;

revoke all on function public.get_treasury_balances(uuid) from public, anon, authenticated;
grant execute on function public.get_treasury_balances(uuid) to authenticated, service_role;

-- record_cash_opening_balance(uuid,numeric,date,text)
CREATE OR REPLACE FUNCTION public.record_cash_opening_balance(p_business_id uuid, p_amount numeric, p_as_of_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.deposit') then
    raise exception 'Not authorized to set opening cash balance';
  end if;
  if p_amount is null or p_amount<0 then raise exception 'Opening cash balance cannot be negative'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  if exists(select 1 from public.cash_transactions where business_id=p_business_id) then
    raise exception 'Opening balance can only be set before the first cash transaction';
  end if;
  if p_amount=0 then
    insert into public.audit_log(business_id,actor_id,action,entity_type,details)
    values(p_business_id,auth.uid(),'opening_balance_zero','cash',jsonb_build_object('as_of_date',p_as_of_date));
    return null;
  end if;
  insert into public.cash_transactions(
    business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by
  ) values (
    p_business_id,coalesce(p_as_of_date,current_date),'in','opening_balance',p_amount,
    'رصيد افتتاحي للخزنة',p_notes,auth.uid()
  ) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'opening_balance','cash_transaction',v_id,
    jsonb_build_object('amount',p_amount,'as_of_date',p_as_of_date));
  return v_id;
end;
$function$;

revoke all on function public.record_cash_opening_balance(uuid,numeric,date,text) from public, anon, authenticated;
grant execute on function public.record_cash_opening_balance(uuid,numeric,date,text) to authenticated, service_role;

-- record_expense(uuid,text,numeric,date,text,text)
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
$function$;

revoke all on function public.record_expense(uuid,text,numeric,date,text,text) from public, anon, authenticated;
grant execute on function public.record_expense(uuid,text,numeric,date,text,text) to authenticated, service_role;

-- record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)
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
  if p_method='cash' and not public.has_business_permission(p_business_id,
    case when v_direction='in' then 'cash.create' else 'cash.withdraw' end) then
    raise exception 'Not authorized to change cash balance';
  end if;
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
$function$;

revoke all on function public.record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text) from public, anon, authenticated;
grant execute on function public.record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text) to authenticated, service_role;

-- record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)
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
 if p_method='cash' and not public.has_business_permission(p_business_id,
   case when v_direction='in' then 'cash.create' else 'cash.withdraw' end) then
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
$function$;

revoke all on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) from public, anon, authenticated;
grant execute on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) to authenticated, service_role;

-- record_treasury_deposit(uuid,text,numeric,text,date,text)
CREATE OR REPLACE FUNCTION public.record_treasury_deposit(p_business_id uuid, p_method text, p_amount numeric, p_reason text, p_transaction_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare v_method text:=lower(trim(coalesce(p_method,''))); v_id uuid; v_amount numeric(14,2):=round(p_amount,2);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.deposit') then raise exception 'Not authorized to deposit treasury funds'; end if;
  if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then raise exception 'Choose a supported treasury account'; end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 or coalesce(trim(p_reason),'')='' then raise exception 'Positive amount and deposit reason are required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,account_method)
  values(p_business_id,coalesce(p_transaction_date,current_date),'in','deposit',v_amount,trim(p_reason),nullif(trim(coalesce(p_notes,'')),''),auth.uid(),v_method) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'treasury_deposit','cash_transaction',v_id,jsonb_build_object('amount',v_amount,'reason',trim(p_reason),'method',v_method));
  return v_id;
end; $function$;

revoke all on function public.record_treasury_deposit(uuid,text,numeric,text,date,text) from public, anon, authenticated;
grant execute on function public.record_treasury_deposit(uuid,text,numeric,text,date,text) to authenticated, service_role;

-- record_treasury_withdrawal(uuid,text,numeric,text,date,text)
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
end; $function$;

revoke all on function public.record_treasury_withdrawal(uuid,text,numeric,text,date,text) from public, anon, authenticated;
grant execute on function public.record_treasury_withdrawal(uuid,text,numeric,text,date,text) to authenticated, service_role;

-- reverse_treasury_transfer(uuid,uuid)
CREATE OR REPLACE FUNCTION public.reverse_treasury_transfer(p_business_id uuid, p_transfer_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_original public.treasury_transfers%rowtype;
  v_existing uuid;
  v_reversal_id uuid;
  v_available numeric(14,2);
  v_label_source text;
  v_label_destination text;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'treasury_transfer.reverse')
  then raise exception 'Not authorized to reverse treasury transfers'; end if;

  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  select * into v_original from public.treasury_transfers
  where business_id=p_business_id and id=p_transfer_id for update;
  if not found then raise exception 'Treasury transfer not found'; end if;
  if v_original.reversal_of_transfer_id is not null then
    raise exception 'A reversal transfer cannot be reversed'; end if;

  select id into v_existing from public.treasury_transfers
  where business_id=p_business_id and reversal_of_transfer_id=p_transfer_id limit 1;
  if v_existing is not null then raise exception 'This treasury transfer has already been reversed'; end if;

  if v_original.destination_method='cash' then
    select coalesce(balance,0) into v_available from public.cash_balances
    where business_id=p_business_id;
    v_available:=coalesce(v_available,0);
  else
    select
      coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
        from public.payments p where p.business_id=p_business_id
          and lower(p.method)=v_original.destination_method),0)
      + coalesce((select sum(case
          when t.destination_method=v_original.destination_method then t.amount
          when t.source_method=v_original.destination_method then -t.amount else 0 end)
        from public.treasury_transfers t where t.business_id=p_business_id),0)
      + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
        from public.cash_transactions c where c.business_id=p_business_id
          and c.account_method=v_original.destination_method and c.payment_id is null
          and c.treasury_transfer_id is null),0)
    into v_available;
  end if;

  if coalesce(v_available,0)<v_original.amount then
    raise exception 'Insufficient source balance to reverse transfer. Available: %',coalesce(v_available,0); end if;

  v_label_source:=case v_original.destination_method when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;
  v_label_destination:=case v_original.source_method when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;

  insert into public.treasury_transfers(
    business_id,transfer_date,source_method,destination_method,amount,notes,created_by,reversal_of_transfer_id
  ) values(p_business_id,current_date,v_original.destination_method,v_original.source_method,
    v_original.amount,'عكس التحويل رقم '||v_original.transfer_code,auth.uid(),p_transfer_id)
  returning id into v_reversal_id;

  if v_original.destination_method='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,
      created_by,treasury_transfer_id,account_method
    ) values(p_business_id,current_date,'out','other',v_original.amount,
      'عكس تحويل رصيد إلى '||v_label_destination,'عكس التحويل رقم '||v_original.transfer_code,
      auth.uid(),v_reversal_id,'cash');
  elsif v_original.source_method='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,
      created_by,treasury_transfer_id,account_method
    ) values(p_business_id,current_date,'in','other',v_original.amount,
      'عكس تحويل رصيد من '||v_label_source,'عكس التحويل رقم '||v_original.transfer_code,
      auth.uid(),v_reversal_id,'cash');
  end if;

  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'reverse_treasury_transfer','treasury_transfer',v_reversal_id,
    jsonb_build_object('original_transfer_id',p_transfer_id,
      'original_transfer_code',v_original.transfer_code,'reversal_transfer_id',v_reversal_id,
      'amount',v_original.amount,'source_method',v_original.destination_method,
      'destination_method',v_original.source_method));
  return v_reversal_id;
end;
$function$;

revoke all on function public.reverse_treasury_transfer(uuid,uuid) from public, anon, authenticated;
grant execute on function public.reverse_treasury_transfer(uuid,uuid) to authenticated, service_role;

-- set_party_opening_balance(uuid,uuid,numeric,text)
CREATE OR REPLACE FUNCTION public.set_party_opening_balance(p_business_id uuid, p_party_id uuid, p_amount numeric, p_side text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'parties.edit') then
    raise exception 'Not authorized to edit party opening balance';
  end if;
  if p_amount is null or p_amount<0 or p_side not in ('receivable','payable') then
    raise exception 'Invalid opening balance amount or side';
  end if;
  perform 1 from public.parties
  where id=p_party_id and business_id=p_business_id
  for update;
  if not found then raise exception 'Party not found in this business'; end if;
  if exists(select 1 from public.sales_invoices where business_id=p_business_id and customer_id=p_party_id)
     or exists(select 1 from public.purchase_invoices where business_id=p_business_id and supplier_id=p_party_id)
     or exists(select 1 from public.payments where business_id=p_business_id and party_id=p_party_id)
     or exists(select 1 from public.sales_returns where business_id=p_business_id and customer_id=p_party_id) then
    raise exception 'Opening balance cannot be changed after account activity exists';
  end if;
  update public.parties
  set opening_balance=p_amount,opening_balance_side=p_side
  where id=p_party_id and business_id=p_business_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'set_opening_balance','party',p_party_id,
    jsonb_build_object('amount',p_amount,'side',p_side));
end;
$function$;

revoke all on function public.set_party_opening_balance(uuid,uuid,numeric,text) from public, anon, authenticated;
grant execute on function public.set_party_opening_balance(uuid,uuid,numeric,text) to authenticated, service_role;

commit;

-- Review notes:
-- * All ten source functions are SECURITY DEFINER with search_path=''.
-- * All ten source functions check auth.uid() and has_business_permission().
-- * No dynamic SQL is used in this batch.
-- * record_expense creates its expense and cash ledger rows in one transaction.
-- * get_treasury_balances reads the split account balances and must follow the views stage.
-- * treasury transfer creation/reversal must be tested for cash/non-cash source/destination pairs,
--   duplicate reversal, insufficient balance, and permission boundaries.
-- * This file has not been executed on Test or Production.
