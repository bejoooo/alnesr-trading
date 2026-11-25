CREATE OR REPLACE FUNCTION public.has_business_permission(bid uuid, permission_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.business_members m
    where m.business_id = bid and m.user_id = auth.uid() and m.active = true
      and (
        m.role in ('owner', 'admin')
        or case when m.permissions ? permission_key
          then m.permissions -> permission_key = 'true'::jsonb
          else case m.role
            when 'manager' then permission_key in (
              'products.view','products.create','products.edit',
              'parties.view','parties.create','parties.edit',
              'purchases.view','purchases.create','purchases.edit',
              'sales.view','sales.create','sales.edit',
              'payments.view','payments.create','payments.record',
              'inventory.view','inventory.create',
              'expenses.view','expenses.create','expenses.edit',
              'cash.view','cash.create','cash.deposit','cash.withdraw',
              'treasury_transfer.view','treasury_transfer.create','treasury_transfer.reverse',
              'settings.view'
            )
            when 'cashier' then permission_key in (
              'products.view','parties.view','parties.create',
              'sales.view','sales.create','sales.edit',
              'payments.view','payments.create','payments.record',
              'inventory.view','cash.view','cash.create',
              'treasury_transfer.view','treasury_transfer.create','treasury_transfer.reverse'
            )
            when 'viewer' then permission_key in (
              'products.view','parties.view','purchases.view','sales.view',
              'payments.view','inventory.view','expenses.view','cash.view',
              'settings.view','audit.view'
            )
            else false
          end
        end
      )
  );
$function$


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
$function$


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
    or not public.has_business_permission(p_business_id,'cash.view')
    or not public.has_business_permission(p_business_id,'payments.view')
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
$function$


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
$function$


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
$function$


REVOKE ALL ON FUNCTION public.get_treasury_balances(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_treasury_balances(uuid) TO authenticated, service_role;

DROP POLICY IF EXISTS treasury_transfers_read ON public.treasury_transfers;
CREATE POLICY treasury_transfers_read ON public.treasury_transfers FOR SELECT TO authenticated USING (public.has_business_permission(business_id, 'treasury_transfer.view'));
