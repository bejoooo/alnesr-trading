-- Allow manual deposits and withdrawals in every treasury account.
-- All existing movements remain cash by default, preserving historical balances.

alter table public.cash_transactions
  add column if not exists account_method text not null default 'cash';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.cash_transactions'::regclass
      and conname='cash_transactions_account_method_check'
  ) then
    alter table public.cash_transactions
      add constraint cash_transactions_account_method_check
      check (account_method in ('cash','instapay','bank_transfer','mobile_wallet','other'));
  end if;
end $$;

create index if not exists cash_transactions_business_account_date_idx
  on public.cash_transactions(business_id,account_method,transaction_date desc,created_at desc);

create or replace view public.cash_balances
with (security_invoker=true) as
select business_id,
       coalesce(sum(case when direction='in' then amount else -amount end),0)::numeric(14,2) as balance
from public.cash_transactions
where account_method='cash'
group by business_id;

create or replace view public.daily_business_summary
with (security_invoker=true) as
with report_dates as (
  select business_id,invoice_date as report_date from public.sales_invoices where status<>'void'
  union
  select business_id,invoice_date from public.purchase_invoices where status<>'void'
  union
  select business_id,expense_date from public.expenses where status<>'void'
  union
  select business_id,transaction_date from public.cash_transactions
  union
  select p.business_id,p.payment_date from public.payments p
  where (p.invoice_id is null
    or exists(select 1 from public.sales_invoices si where si.id=p.invoice_id and si.business_id=p.business_id and si.status<>'void')
    or exists(select 1 from public.purchase_invoices pi where pi.id=p.invoice_id and pi.business_id=p.business_id and pi.status<>'void'))
    and (p.sales_return_id is null
      or exists(select 1 from public.sales_returns sr where sr.id=p.sales_return_id and sr.business_id=p.business_id and sr.status<>'void'))
)
select d.business_id,d.report_date,
  coalesce((select sum(si.total) from public.sales_invoices si where si.business_id=d.business_id and si.invoice_date=d.report_date and si.status<>'void'),0)::numeric(14,2) as sales_total,
  coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end) from public.payments p
    where p.business_id=d.business_id and p.payment_date=d.report_date and p.sales_return_id is null
      and (exists(select 1 from public.sales_invoices si where si.id=p.invoice_id and si.business_id=p.business_id and si.status<>'void')
        or p.invoice_id is null and p.party_account_type='customer')),0)::numeric(14,2) as sales_collected,
  coalesce((select sum(si.due_total) from public.sales_invoices si where si.business_id=d.business_id and si.invoice_date=d.report_date and si.status<>'void'),0)::numeric(14,2) as sales_outstanding,
  coalesce((select sum(pi.total) from public.purchase_invoices pi where pi.business_id=d.business_id and pi.invoice_date=d.report_date and pi.status<>'void'),0)::numeric(14,2) as purchases_total,
  coalesce((select sum(case when p.direction='out' then p.amount else -p.amount end) from public.payments p
    where p.business_id=d.business_id and p.payment_date=d.report_date and p.sales_return_id is null
      and (exists(select 1 from public.purchase_invoices pi where pi.id=p.invoice_id and pi.business_id=p.business_id and pi.status<>'void')
        or p.invoice_id is null and p.party_account_type='supplier')),0)::numeric(14,2) as purchases_paid,
  coalesce((select sum(e.amount) from public.expenses e where e.business_id=d.business_id and e.expense_date=d.report_date and e.status<>'void'),0)::numeric(14,2) as expenses_total,
  coalesce((select sum(c.amount) from public.cash_transactions c where c.business_id=d.business_id and c.transaction_date=d.report_date and c.direction='in' and c.account_method='cash'),0)::numeric(14,2) as cash_in,
  coalesce((select sum(c.amount) from public.cash_transactions c where c.business_id=d.business_id and c.transaction_date=d.report_date and c.direction='out' and c.account_method='cash'),0)::numeric(14,2) as cash_out
from report_dates d;

create or replace function public.record_treasury_deposit(
  p_business_id uuid,
  p_method text,
  p_amount numeric,
  p_reason text,
  p_transaction_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_method text := lower(trim(coalesce(p_method,'')));
  v_id uuid;
  v_amount numeric(14,2) := round(p_amount,2);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.deposit') then
    raise exception 'Not authorized to deposit treasury funds';
  end if;
  if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then
    raise exception 'Choose a supported treasury account';
  end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 or coalesce(trim(p_reason),'')='' then
    raise exception 'Positive amount and deposit reason are required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  insert into public.cash_transactions(
    business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,account_method
  ) values (
    p_business_id,coalesce(p_transaction_date,current_date),'in','deposit',v_amount,
    trim(p_reason),nullif(trim(coalesce(p_notes,'')),''),auth.uid(),v_method
  ) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'treasury_deposit','cash_transaction',v_id,
    jsonb_build_object('amount',v_amount,'reason',trim(p_reason),'method',v_method));
  return v_id;
end;
$$;

create or replace function public.record_treasury_withdrawal(
  p_business_id uuid,
  p_method text,
  p_amount numeric,
  p_reason text,
  p_transaction_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_method text := lower(trim(coalesce(p_method,'')));
  v_id uuid;
  v_available numeric(14,2);
  v_amount numeric(14,2) := round(p_amount,2);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.withdraw') then
    raise exception 'Not authorized to withdraw treasury funds';
  end if;
  if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then
    raise exception 'Choose a supported treasury account';
  end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 or coalesce(trim(p_reason),'')='' then
    raise exception 'Positive amount and withdrawal reason are required';
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
        from public.cash_transactions c where c.business_id=p_business_id and c.account_method=v_method),0)
    into v_available;
  end if;
  if coalesce(v_available,0)<v_amount then
    raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0);
  end if;
  insert into public.cash_transactions(
    business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,account_method
  ) values (
    p_business_id,coalesce(p_transaction_date,current_date),'out','other',v_amount,
    trim(p_reason),nullif(trim(coalesce(p_notes,'')),''),auth.uid(),v_method
  ) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'treasury_withdrawal','cash_transaction',v_id,
    jsonb_build_object('amount',v_amount,'reason',trim(p_reason),'method',v_method));
  return v_id;
end;
$$;

create or replace function public.create_treasury_transfer(
  p_business_id uuid,
  p_source_method text,
  p_destination_method text,
  p_amount numeric,
  p_transfer_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_source text := lower(trim(coalesce(p_source_method,'')));
  v_destination text := lower(trim(coalesce(p_destination_method,'')));
  v_amount numeric(14,2) := round(p_amount,2);
  v_available numeric(14,2);
  v_transfer_id uuid;
  v_label_source text;
  v_label_destination text;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.create')
    or not public.has_business_permission(p_business_id,'cash.view')
    or not public.has_business_permission(p_business_id,'payments.view') then
    raise exception 'Not authorized to transfer treasury balances';
  end if;
  if v_source not in ('cash','instapay','bank_transfer','mobile_wallet','other')
    or v_destination not in ('cash','instapay','bank_transfer','mobile_wallet','other')
    or v_source=v_destination then
    raise exception 'Choose two different supported balance accounts';
  end if;
  if p_amount is null or p_amount<=0 or v_amount<=0 then
    raise exception 'Transfer amount must be positive';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  if v_source='cash' then
    select coalesce(balance,0) into v_available from public.cash_balances where business_id=p_business_id;
    v_available:=coalesce(v_available,0);
  else
    select
      coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
        from public.payments p where p.business_id=p_business_id and lower(p.method)=v_source),0)
      + coalesce((select sum(case when t.destination_method=v_source then t.amount
                                  when t.source_method=v_source then -t.amount else 0 end)
        from public.treasury_transfers t where t.business_id=p_business_id),0)
      + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
        from public.cash_transactions c where c.business_id=p_business_id and c.account_method=v_source),0)
    into v_available;
  end if;
  if coalesce(v_available,0)<v_amount then
    raise exception 'Insufficient source balance. Available: %',coalesce(v_available,0);
  end if;
  insert into public.treasury_transfers(
    business_id,transfer_date,source_method,destination_method,amount,notes,created_by
  ) values (
    p_business_id,coalesce(p_transfer_date,current_date),v_source,v_destination,v_amount,
    nullif(trim(coalesce(p_notes,'')),''),auth.uid()
  ) returning id into v_transfer_id;

  v_label_source:=case v_source when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;
  v_label_destination:=case v_destination when 'cash' then 'الخزنة النقدية'
    when 'instapay' then 'إنستاباي' when 'bank_transfer' then 'التحويل البنكي'
    when 'mobile_wallet' then 'المحفظة الإلكترونية' else 'أخرى' end;

  if v_source='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,treasury_transfer_id,account_method
    ) values (
      p_business_id,coalesce(p_transfer_date,current_date),'out','other',v_amount,
      'تحويل رصيد إلى '||v_label_destination,
      coalesce(nullif(trim(coalesce(p_notes,'')),''),'تحويل داخلي بين الأرصدة'),
      auth.uid(),v_transfer_id,'cash'
    );
  elsif v_destination='cash' then
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,treasury_transfer_id,account_method
    ) values (
      p_business_id,coalesce(p_transfer_date,current_date),'in','other',v_amount,
      'تحويل رصيد من '||v_label_source,
      coalesce(nullif(trim(coalesce(p_notes,'')),''),'تحويل داخلي بين الأرصدة'),
      auth.uid(),v_transfer_id,'cash'
    );
  end if;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'create_treasury_transfer','treasury_transfer',v_transfer_id,
    jsonb_build_object('source_method',v_source,'destination_method',v_destination,'amount',v_amount,
      'transfer_date',coalesce(p_transfer_date,current_date)));
  return v_transfer_id;
end;
$$;

create or replace function public.owner_remove_cash_transaction(p_business_id uuid,p_transaction_id uuid)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tx record;
  v_balance numeric(14,2);
  v_reversal_id uuid;
begin
  if auth.uid() is null or not exists(
    select 1 from public.business_members
    where business_id=p_business_id and user_id=auth.uid() and role='owner' and active
  ) then raise exception 'Only the active business owner can reverse cash transactions'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  select * into v_tx from public.cash_transactions
  where id=p_transaction_id and business_id=p_business_id for update;
  if not found then raise exception 'Cash transaction not found'; end if;
  if v_tx.reversal_of_transaction_id is not null then raise exception 'A reversal entry cannot itself be reversed here'; end if;
  if exists(select 1 from public.cash_transactions r where r.reversal_of_transaction_id=v_tx.id) then
    raise exception 'This cash movement has already been reversed';
  end if;
  if v_tx.invoice_id is not null or v_tx.party_id is not null or v_tx.sales_return_id is not null
    or v_tx.treasury_transfer_id is not null
    or exists(select 1 from public.expenses e where e.cash_transaction_id=v_tx.id)
    or v_tx.transaction_type not in ('deposit','other') then
    raise exception 'This cash movement is linked to an invoice, expense, refund, or opening balance and cannot be removed here';
  end if;
  if v_tx.account_method='cash' then
    select coalesce(balance,0) into v_balance from public.cash_balances where business_id=p_business_id;
    v_balance:=coalesce(v_balance,0);
  else
    select
      coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end)
        from public.payments p where p.business_id=p_business_id and lower(p.method)=v_tx.account_method),0)
      + coalesce((select sum(case when t.destination_method=v_tx.account_method then t.amount
                                  when t.source_method=v_tx.account_method then -t.amount else 0 end)
        from public.treasury_transfers t where t.business_id=p_business_id),0)
      + coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end)
        from public.cash_transactions c where c.business_id=p_business_id and c.account_method=v_tx.account_method),0)
    into v_balance;
  end if;
  if v_tx.direction='in' and coalesce(v_balance,0)<v_tx.amount then
    raise exception 'Treasury balance is insufficient to reverse this deposit';
  end if;
  insert into public.cash_transactions(
    business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by,
    reversal_of_transaction_id,account_method
  ) values (
    p_business_id,current_date,case when v_tx.direction='in' then 'out' else 'in' end,'other',v_tx.amount,
    'عكس حركة خزنة: '||coalesce(v_tx.reason,'بدون بيان'),
    'عكس الحركة الأصلية رقم '||p_transaction_id,auth.uid(),v_tx.id,v_tx.account_method
  ) returning id into v_reversal_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'remove_reversed','cash_transaction',p_transaction_id,
    jsonb_build_object('amount',v_tx.amount,'original_direction',v_tx.direction,
      'account_method',v_tx.account_method,'reversal_id',v_reversal_id));
  return 'reversed';
end;
$$;

revoke all on function public.record_treasury_deposit(uuid,text,numeric,text,date,text) from public,anon;
revoke all on function public.record_treasury_withdrawal(uuid,text,numeric,text,date,text) from public,anon;
grant execute on function public.record_treasury_deposit(uuid,text,numeric,text,date,text) to authenticated;
grant execute on function public.record_treasury_withdrawal(uuid,text,numeric,text,date,text) to authenticated;
