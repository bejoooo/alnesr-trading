create or replace function public.record_standalone_party_payment(
 p_business_id uuid,
 p_party_id uuid,
 p_account_type text,
 p_amount numeric,
 p_payment_date date default current_date,
 p_method text default 'cash',
 p_reference text default null,
 p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
 v_party public.parties%rowtype;
 v_direction text;
 v_payment_id uuid;
 v_cash_balance numeric(14,2);
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'payments.create') then
  raise exception 'Not authorized to record payments';
 end if;
 if p_account_type is null or p_account_type not in ('customer','supplier') then
  raise exception 'Choose whether this payment belongs to the customer or supplier account';
 end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment must be positive'; end if;
 p_method:=lower(btrim(coalesce(p_method,'cash')));
 if p_method not in ('cash','bank_transfer','instapay','other') then
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
 if p_method='cash' then
  if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to change cash balance'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_cash_balance from public.cash_transactions where business_id=p_business_id;
  if v_direction='out' and v_cash_balance<p_amount then
   raise exception 'Insufficient cash balance for this supplier payment';
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
revoke all on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) from public,anon;
grant execute on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) to authenticated;
