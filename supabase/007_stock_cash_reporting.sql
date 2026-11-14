-- Al Nesr Trading — stock controls, opening cash and operational reporting
-- Apply after 006_invoice_reference_integrity.sql on a TEST project first.

create or replace function public.post_stock_adjustment(
  p_business_id uuid,
  p_product_id uuid,
  p_quantity_delta numeric,
  p_reason text,
  p_movement_date date default current_date,
  p_unit_cost numeric default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product public.products%rowtype;
  v_on_hand numeric(14,3);
  v_new_qty numeric(14,3);
  v_cost numeric(14,4);
  v_new_avg numeric(14,2);
  v_type text;
  v_id uuid;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'inventory.create') then
    raise exception 'Not authorized to adjust inventory';
  end if;
  if p_quantity_delta is null or p_quantity_delta=0 or coalesce(trim(p_reason),'')='' then
    raise exception 'A non-zero quantity and reason are required';
  end if;

  select * into v_product from public.products
  where id=p_product_id and business_id=p_business_id and is_active=true
  for update;
  if not found then raise exception 'Product not found in this business'; end if;

  select coalesce(sum(quantity_delta),0) into v_on_hand
  from public.stock_movements
  where business_id=p_business_id and product_id=p_product_id;
  v_new_qty := v_on_hand+p_quantity_delta;
  if v_new_qty<0 then raise exception 'Stock adjustment cannot make inventory negative'; end if;

  if p_quantity_delta>0 then
    v_type := 'adjustment_in';
    v_cost := coalesce(p_unit_cost,v_product.average_cost);
    if v_cost<0 then raise exception 'Unit cost cannot be negative'; end if;
    v_new_avg := case when v_new_qty=0 then 0
      else round(((v_on_hand*v_product.average_cost)+(p_quantity_delta*v_cost))/v_new_qty,2) end;
  else
    v_type := 'adjustment_out';
    v_cost := v_product.average_cost;
    v_new_avg := v_product.average_cost;
  end if;

  insert into public.stock_movements(
    business_id,product_id,movement_date,movement_type,quantity_delta,
    unit_cost,source_type,notes,created_by
  ) values (
    p_business_id,p_product_id,coalesce(p_movement_date,current_date),v_type,
    p_quantity_delta,v_cost,'manual_adjustment',trim(p_reason),auth.uid()
  ) returning id into v_id;

  update public.products set average_cost=v_new_avg,updated_at=now() where id=p_product_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'stock_adjustment','stock_movement',v_id,
    jsonb_build_object('product_id',p_product_id,'quantity_delta',p_quantity_delta,'reason',p_reason,'new_balance',v_new_qty));
  return v_id;
end;
$$;

create or replace function public.record_cash_opening_balance(
  p_business_id uuid,
  p_amount numeric,
  p_as_of_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.deposit') then
    raise exception 'Not authorized to set opening cash balance';
  end if;
  if p_amount is null or p_amount<0 then raise exception 'Opening cash balance cannot be negative'; end if;
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
$$;

create or replace view public.product_stock_balances
with (security_invoker=true) as
select p.business_id,p.id as product_id,p.code,p.name,p.unit,p.minimum_stock,
       coalesce(sum(sm.quantity_delta),0)::numeric(14,3) as quantity_on_hand,
       p.average_cost,
       (coalesce(sum(sm.quantity_delta),0)*p.average_cost)::numeric(14,2) as stock_value,
       (coalesce(sum(sm.quantity_delta),0)<=p.minimum_stock) as below_minimum
from public.products p
left join public.stock_movements sm
  on sm.business_id=p.business_id and sm.product_id=p.id
where p.is_active=true
group by p.business_id,p.id,p.code,p.name,p.unit,p.minimum_stock,p.average_cost;

create or replace view public.cash_balances
with (security_invoker=true) as
select business_id,
       coalesce(sum(case when direction='in' then amount else -amount end),0)::numeric(14,2) as balance
from public.cash_transactions
group by business_id;

create or replace view public.daily_business_summary
with (security_invoker=true) as
with report_dates as (
  select business_id,invoice_date as report_date from public.sales_invoices
  union
  select business_id,invoice_date from public.purchase_invoices
  union
  select business_id,expense_date from public.expenses
  union
  select business_id,transaction_date from public.cash_transactions
)
select d.business_id,d.report_date,
       coalesce(s.sales_total,0)::numeric(14,2) as sales_total,
       coalesce(s.sales_paid,0)::numeric(14,2) as sales_collected,
       coalesce(s.sales_due,0)::numeric(14,2) as sales_outstanding,
       coalesce(p.purchase_total,0)::numeric(14,2) as purchases_total,
       coalesce(p.purchase_paid,0)::numeric(14,2) as purchases_paid,
       coalesce(e.expenses_total,0)::numeric(14,2) as expenses_total,
       coalesce(c.cash_in,0)::numeric(14,2) as cash_in,
       coalesce(c.cash_out,0)::numeric(14,2) as cash_out
from report_dates d
left join lateral (
  select sum(total) sales_total,sum(paid_total) sales_paid,sum(due_total) sales_due
  from public.sales_invoices x
  where x.business_id=d.business_id and x.invoice_date=d.report_date and x.status<>'void'
) s on true
left join lateral (
  select sum(total) purchase_total,sum(paid_total) purchase_paid
  from public.purchase_invoices x
  where x.business_id=d.business_id and x.invoice_date=d.report_date and x.status<>'void'
) p on true
left join lateral (
  select sum(amount) expenses_total from public.expenses x
  where x.business_id=d.business_id and x.expense_date=d.report_date
) e on true
left join lateral (
  select sum(case when direction='in' then amount else 0 end) cash_in,
         sum(case when direction='out' then amount else 0 end) cash_out
  from public.cash_transactions x
  where x.business_id=d.business_id and x.transaction_date=d.report_date
) c on true;


create or replace function public.record_cash_withdrawal(
  p_business_id uuid,
  p_amount numeric,
  p_reason text,
  p_transaction_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'cash.withdraw') then
    raise exception 'Not authorized to withdraw cash';
  end if;
  if p_amount is null or p_amount<=0 or coalesce(trim(p_reason),'')='' then
    raise exception 'Positive amount and withdrawal reason are required';
  end if;
  if coalesce((select sum(case when direction='in' then amount else -amount end)\n              from public.cash_transactions where business_id=p_business_id),0)<p_amount then
    raise exception 'Cash withdrawal exceeds available cash balance';
  end if;
  insert into public.cash_transactions(
    business_id,transaction_date,direction,transaction_type,amount,reason,notes,created_by
  ) values (
    p_business_id,coalesce(p_transaction_date,current_date),'out','other',
    p_amount,trim(p_reason),p_notes,auth.uid()
  ) returning id into v_id;
  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'cash_withdrawal','cash_transaction',v_id,
    jsonb_build_object('amount',p_amount,'reason',p_reason));
  return v_id;
end;
$$;

revoke all on function public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric) from public,anon;
revoke all on function public.record_cash_opening_balance(uuid,numeric,date,text) from public,anon;\nrevoke all on function public.record_cash_withdrawal(uuid,numeric,text,date,text) from public,anon;
grant execute on function public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric) to authenticated;
grant execute on function public.record_cash_opening_balance(uuid,numeric,date,text) to authenticated;\ngrant execute on function public.record_cash_withdrawal(uuid,numeric,text,date,text) to authenticated;

grant select on public.product_stock_balances to authenticated;
grant select on public.cash_balances to authenticated;
grant select on public.daily_business_summary to authenticated;
