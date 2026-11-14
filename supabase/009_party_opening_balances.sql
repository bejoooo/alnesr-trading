-- Al Nesr Trading — explicit opening balance side for parties
-- Apply after 008_party_accounts_reporting.sql.

alter table public.parties
  add column if not exists opening_balance_side text not null default 'receivable'
  check (opening_balance_side in ('receivable','payable'));

create or replace function public.set_party_opening_balance(
  p_business_id uuid,
  p_party_id uuid,
  p_amount numeric,
  p_side text
) returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

create or replace view public.party_account_balances
with (security_invoker=true) as
select p.business_id,p.id as party_id,p.kind,p.name,p.phone,
       p.opening_balance::numeric(14,2) as opening_balance,
       p.opening_balance_side,
       coalesce(s.sales_total,0)::numeric(14,2) as sales_total,
       coalesce(pi.purchases_total,0)::numeric(14,2) as purchases_total,
       coalesce(pay.customer_paid,0)::numeric(14,2) as customer_payments,
       coalesce(pay.supplier_paid,0)::numeric(14,2) as supplier_payments,
       coalesce(r.returns_total,0)::numeric(14,2) as returns_total,
       (case when p.kind in ('customer','both') then
          (case when p.opening_balance_side='receivable' then p.opening_balance else 0 end)
          +coalesce(s.sales_total,0)-coalesce(pay.customer_paid,0)-coalesce(r.returns_total,0)
          +coalesce(pay.customer_refunds,0)
        else 0 end)::numeric(14,2) as customer_net_balance,
       (case when p.kind in ('supplier','both') then
          (case when p.opening_balance_side='payable' then p.opening_balance else 0 end)
          +coalesce(pi.purchases_total,0)-coalesce(pay.supplier_paid,0)
        else 0 end)::numeric(14,2) as supplier_net_balance
from public.parties p
left join lateral (
  select sum(total) as sales_total from public.sales_invoices x
  where x.business_id=p.business_id and x.customer_id=p.id and x.status<>'void'
) s on true
left join lateral (
  select sum(total) as purchases_total from public.purchase_invoices x
  where x.business_id=p.business_id and x.supplier_id=p.id and x.status<>'void'
) pi on true
left join lateral (
  select sum(case when x.direction='in' then x.amount else 0 end) as customer_paid,
         sum(case when x.direction='out' then x.amount else 0 end) as supplier_paid,
         sum(case when x.direction='out' and exists (
           select 1 from public.sales_invoices si
           where si.id=x.invoice_id and si.business_id=x.business_id
             and si.customer_id=p.id
         ) then x.amount else 0 end) as customer_refunds
  from public.payments x
  where x.business_id=p.business_id and x.party_id=p.id
) pay on true
left join lateral (
  select sum(refund_total) as returns_total from public.sales_returns x
  where x.business_id=p.business_id and x.customer_id=p.id
) r on true;

create or replace view public.party_account_statement
with (security_invoker=true) as
select p.business_id,p.id as party_id,p.name as party_name,
       'opening_balance'::text as entry_type,
       null::uuid as entry_id,null::text as reference_no,
       p.created_at::date as entry_date,
       case when p.opening_balance_side='receivable' then p.opening_balance else 0 end::numeric(14,2) as debit,
       case when p.opening_balance_side='payable' then p.opening_balance else 0 end::numeric(14,2) as credit,
       'رصيد افتتاحي'::text as description
from public.parties p
where p.opening_balance<>0
union all
select i.business_id,i.customer_id,p.name,'sale_invoice',i.id,i.invoice_no,
       i.invoice_date,i.total,0,'فاتورة مبيعات'
from public.sales_invoices i
join public.parties p on p.id=i.customer_id and p.business_id=i.business_id
where i.customer_id is not null and i.status<>'void'
union all
select i.business_id,i.supplier_id,p.name,'purchase_invoice',i.id,i.invoice_no,
       i.invoice_date,0,i.total,'فاتورة مشتريات'
from public.purchase_invoices i
join public.parties p on p.id=i.supplier_id and p.business_id=i.business_id
where i.supplier_id is not null and i.status<>'void'
union all
select x.business_id,x.party_id,p.name,'payment',x.id,x.reference,
       x.payment_date,
       case when x.direction='out' then x.amount else 0 end,
       case when x.direction='in' then x.amount else 0 end,
       coalesce(x.notes,'دفعة')
from public.payments x
join public.parties p on p.id=x.party_id and p.business_id=x.business_id
where x.party_id is not null
union all
select r.business_id,r.customer_id,p.name,'sales_return',r.id,r.return_no,
       r.return_date,0,r.refund_total,'مرتجع مبيعات'
from public.sales_returns r
join public.parties p on p.id=r.customer_id and p.business_id=r.business_id
where r.customer_id is not null;

revoke all on function public.set_party_opening_balance(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.set_party_opening_balance(uuid,uuid,numeric,text) to authenticated;
