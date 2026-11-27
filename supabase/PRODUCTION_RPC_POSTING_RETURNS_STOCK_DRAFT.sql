-- DRAFT ONLY — invoice posting, returns, stock, and customer-credit RPC batch
-- Exact definitions extracted from current Test; both compatibility overloads are retained.
-- Apply only after schema, helper/trigger, view, and first financial RPC stages are approved.
-- This file defines functions but does not invoke them.

begin;
set local search_path = pg_catalog, public;

do $preflight$
declare v_missing text[];
begin
  select array_agg(x.object_name order by x.object_name) into v_missing
  from (values
    ('public.business_members'),('public.businesses'),
    ('public.parties'),('public.products'),
    ('public.purchase_invoices'),('public.purchase_items'),('public.purchase_invoice_cost_snapshots'),
    ('public.sales_invoices'),('public.sales_items'),('public.sales_returns'),('public.sales_return_items'),
    ('public.purchase_returns'),('public.purchase_return_items'),
    ('public.payments'),('public.customer_credit_ledger'),
    ('public.stock_movements'),('public.stock_adjustment_cost_snapshots'),
    ('public.cash_transactions'),('public.expenses'),('public.audit_log'),
    ('public.party_account_balances'),('public.product_stock_balances'),
    ('public.customer_credit_balances'),('public.customer_credit_return_balances')
  ) as x(object_name)
  where to_regclass(x.object_name) is null;

  if v_missing is not null then
    raise exception 'Missing base tables/views for posting RPC batch: %',array_to_string(v_missing,', ');
  end if;

  if to_regprocedure('public.has_business_permission(uuid,text)') is null
     or to_regprocedure('public.next_operation_code(uuid,text)') is null then
    raise exception 'Missing required helper functions for posting RPC batch';
  end if;

  if exists (
    select 1 from (values
      ('purchase_invoices','supplier_credit_applied_total'),
      ('sales_invoices','customer_credit_applied_total'),
      ('sales_invoices','status'),
      ('sales_items','unit_cost_snapshot'),
      ('sales_return_items','unit_price'),
      ('sales_returns','status'),
      ('sales_returns','posted_at'),
      ('payments','sales_return_id'),
      ('payments','purchase_return_id'),
      ('payments','party_account_type'),
      ('payments','reversal_of_payment_id'),
      ('stock_movements','stock_bucket'),
      ('stock_movements','average_cost_before'),
      ('cash_transactions','account_method'),
      ('cash_transactions','sales_return_id'),
      ('cash_transactions','purchase_return_id'),
      ('purchase_returns','status'),
      ('purchase_returns','posted_at'),
      ('customer_credit_ledger','event_type'),
      ('customer_credit_ledger','source_return_id')
    ) as required(table_name,column_name)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public' and c.table_name=required.table_name
        and c.column_name=required.column_name
    )
  ) then
    raise exception 'Missing required columns for posting RPC batch';
  end if;
end
$preflight$;

-- pay_customer_credit(uuid,uuid,numeric,date,text,text,text)
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
end;$function$;

revoke all on function public.pay_customer_credit(uuid,uuid,numeric,date,text,text,text) from public, anon, authenticated;
grant execute on function public.pay_customer_credit(uuid,uuid,numeric,date,text,text,text) to authenticated, service_role;

-- post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)
CREATE OR REPLACE FUNCTION public.post_purchase_return_with_settlement(p_business_id uuid, p_return_no text, p_purchase_invoice_id uuid, p_items jsonb, p_return_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text, p_method text DEFAULT 'cash'::text, p_receive_now boolean DEFAULT true)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_invoice public.purchase_invoices%rowtype; v_generated_code text;
 v_item jsonb; v_purchase_item public.purchase_items%rowtype; v_product public.products%rowtype;
 v_return_id uuid; v_payment_id uuid; v_qty numeric(14,3); v_already numeric(14,3);
 v_on_hand numeric(14,3); v_cost numeric(14,2); v_line numeric(14,2); v_total numeric(14,2):=0;
 v_avg numeric(14,2); v_total_on_hand numeric(14,3); v_original_cost numeric(14,2);
 v_refund numeric(14,2):=0; v_method text:=lower(btrim(coalesce(p_method,'cash')));
 v_supplier_balance numeric(14,2):=0; v_invoice_due_reduced numeric(14,2):=0; v_credit_generated numeric(14,2):=0;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'purchases.create') then
  raise exception 'Not authorized to create a purchase return';
 end if;
 if v_method not in ('cash','bank_transfer','instapay','mobile_wallet','other') then raise exception 'Unsupported refund method'; end if;
 v_generated_code:=public.next_operation_code(p_business_id,'purchase_return');
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one return item is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_invoice from public.purchase_invoices where id=p_purchase_invoice_id and business_id=p_business_id for update;
 if not found or v_invoice.status='void' then raise exception 'Valid purchase invoice not found'; end if;
 select coalesce(supplier_net_balance,0) into v_supplier_balance
 from public.party_account_balances where business_id=p_business_id and party_id=v_invoice.supplier_id;
 v_supplier_balance:=coalesce(v_supplier_balance,0);
 perform 1 from public.products p where p.business_id=p_business_id
  and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x) order by p.id for update;
 insert into public.purchase_returns(business_id,return_no,purchase_invoice_id,supplier_id,return_date,notes,created_by)
 values(p_business_id,v_generated_code,p_purchase_invoice_id,v_invoice.supplier_id,coalesce(p_return_date,current_date),p_notes,auth.uid())
 returning id into v_return_id;
 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_purchase_item from public.purchase_items
   where id=(v_item->>'purchase_item_id')::uuid and invoice_id=p_purchase_invoice_id and business_id=p_business_id for update;
  if not found then raise exception 'Returned item does not belong to the selected purchase invoice'; end if;
  v_qty:=(v_item->>'quantity')::numeric;
  if v_qty<=0 then raise exception 'Return quantity must be positive'; end if;
  if coalesce(v_item->>'condition','') not in ('good','damaged') then raise exception 'Invalid returned item condition'; end if;
  select coalesce(sum(ri.quantity),0) into v_already from public.purchase_return_items ri
   join public.purchase_returns r on r.id=ri.return_id
   where ri.business_id=p_business_id and ri.purchase_item_id=v_purchase_item.id and r.status='posted';
  if v_qty>v_purchase_item.quantity-v_already then raise exception 'Return quantity exceeds the remaining quantity on the purchase item'; end if;
  select * into v_product from public.products where id=v_purchase_item.product_id and business_id=p_business_id for update;
  select coalesce(sum(quantity_delta),0) into v_on_hand from public.stock_movements
   where business_id=p_business_id and product_id=v_product.id
   and stock_bucket=case when v_item->>'condition'='damaged' then 'damaged' else 'sellable' end;
  if v_on_hand<v_qty then raise exception 'Insufficient stock in the selected condition to return this quantity to the supplier'; end if;
  select coalesce(sum(quantity_delta),0) into v_total_on_hand from public.stock_movements where business_id=p_business_id and product_id=v_product.id;
  v_original_cost:=round(coalesce(v_purchase_item.unit_landed_cost,v_purchase_item.unit_price),2);
  v_cost:=round(coalesce(nullif(v_item->>'unit_cost','')::numeric,v_original_cost),2);
  if v_cost<0 then raise exception 'Return unit price cannot be negative'; end if;
  v_line:=round(v_qty*v_cost,2);
  insert into public.purchase_return_items(business_id,return_id,purchase_item_id,product_id,quantity,condition,unit_cost,line_total)
  values(p_business_id,v_return_id,v_purchase_item.id,v_product.id,v_qty,v_item->>'condition',v_cost,v_line);
  insert into public.stock_movements(business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,notes,created_by,stock_bucket)
  values(p_business_id,v_product.id,coalesce(p_return_date,current_date),'purchase_return',-v_qty,v_original_cost,'purchase_return',v_return_id,
   case when v_item->>'condition'='damaged' then 'مرتجع مشتريات تالف للمورد' else 'مرتجع مشتريات صالح للمورد' end,
   auth.uid(),case when v_item->>'condition'='damaged' then 'damaged' else 'sellable' end);
  if v_total_on_hand-v_qty>0 then
   v_avg:=round(greatest(0,((v_total_on_hand*v_product.average_cost)-(v_qty*v_original_cost))/(v_total_on_hand-v_qty)),2);
   update public.products set average_cost=v_avg,updated_at=now() where id=v_product.id;
  end if;
  v_total:=v_total+v_line;
 end loop;
 if v_total<=0 then raise exception 'Purchase return total must be positive'; end if;
 v_refund:=case when v_supplier_balance<0 then 0 else greatest(0,round(v_total-v_supplier_balance,2)) end;
 if v_supplier_balance<0 then v_credit_generated:=v_total;
 elsif not coalesce(p_receive_now,true) then v_credit_generated:=v_refund; v_refund:=0;
 end if;
 v_invoice_due_reduced:=least(coalesce(v_invoice.due_total,0),v_total);
 if v_refund>0 then
  if v_method='cash' then
   if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to receive cash'; end if;
  else
   if not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to receive this payment method'; end if;
  end if;
 end if;
 update public.purchase_returns set total=v_total,credit_generated_total=v_credit_generated,
  invoice_due_reduced_total=v_invoice_due_reduced where id=v_return_id;
 update public.purchase_invoices set due_total=greatest(0,due_total-v_total),
  status=case when greatest(0,due_total-v_total)=0 then case when paid_total>0 then 'paid' else 'posted' end
   when paid_total>0 then 'partially_paid' else 'posted' end
 where id=p_purchase_invoice_id and business_id=p_business_id;
 if v_refund>0 then
  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by,party_account_type,purchase_return_id)
  values(p_business_id,v_invoice.supplier_id,p_purchase_invoice_id,'in',v_refund,coalesce(p_return_date,current_date),v_method,
   'استرداد من المورد مقابل مرتجع مشتريات '||v_generated_code,auth.uid(),'supplier',v_return_id)
  returning id into v_payment_id;
  if v_method='cash' then
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,payment_id,account_method,purchase_return_id)
   values(p_business_id,coalesce(p_return_date,current_date),'in','other',v_refund,v_invoice.supplier_id,p_purchase_invoice_id,
    'استرداد من المورد مقابل مرتجع مشتريات','مرتجع مشتريات '||v_generated_code,auth.uid(),v_payment_id,'cash',v_return_id);
  end if;
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'post','purchase_return',v_return_id,
  jsonb_build_object('purchase_invoice_id',p_purchase_invoice_id,'supplier_id',v_invoice.supplier_id,'total',v_total,
   'supplier_balance_before',v_supplier_balance,'invoice_due_reduced',v_invoice_due_reduced,
   'refund_received',v_refund,'credit_generated_total',v_credit_generated,'refund_method',case when v_refund>0 then v_method else null end));
 return v_return_id;
end;
$function$;

revoke all on function public.post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean) from public, anon, authenticated;
grant execute on function public.post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean) to authenticated, service_role;

-- post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)
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
   if not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to record the cash payment'; end if;
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
$function$;

revoke all on function public.post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean) from public, anon, authenticated;
grant execute on function public.post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean) to authenticated, service_role;

-- post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)
CREATE OR REPLACE FUNCTION public.post_sale_with_method(p_business_id uuid, p_invoice_no text, p_customer_id uuid, p_invoice_date date, p_items jsonb, p_invoice_discount numeric, p_paid_amount numeric, p_notes text, p_method text, p_apply_customer_credit boolean)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_invoice_id uuid; v_generated_code text; v_item jsonb; v_payment_id uuid;
 v_product public.products%rowtype; v_qty numeric(14,3); v_price numeric(14,2);
 v_item_discount numeric(14,2); v_gross numeric(14,2):=0; v_line_discounts numeric(14,2):=0;
 v_discount numeric(14,2); v_total numeric(14,2); v_line_gross numeric(14,2);
 v_extra_discount numeric(14,2); v_final_line_discount numeric(14,2);
 v_discount_used numeric(14,2):=0; v_item_count integer; v_i integer:=0;
 v_on_hand numeric(14,3); v_customer_name text:='عميل نقدي'; v_cost numeric(14,4);
 v_method text:=lower(trim(coalesce(p_method,'cash')));
 v_paid numeric(14,2):=round(coalesce(p_paid_amount,0),2);
 v_credit_available numeric(14,2):=0; v_credit_to_apply numeric(14,2):=0;
 v_credit_remaining numeric(14,2):=0; v_credit_take numeric(14,2):=0; v_credit_row record;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'sales.create') then
  raise exception 'Not authorized to create sales';
 end if;
 if v_method not in ('cash','instapay','bank_transfer','mobile_wallet','other') then
  raise exception 'Choose a supported treasury account';
 end if;
 v_generated_code:=public.next_operation_code(p_business_id,'sales_invoice');
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
  raise exception 'At least one sale item is required';
 end if;
 if coalesce(p_invoice_discount,0)<0 or v_paid<0 then
  raise exception 'Discount and paid amount cannot be negative';
 end if;
 if v_paid>0 then
  if v_method='cash' then
   if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to record the cash receipt'; end if;
  else
   if not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to record this payment method'; end if;
  end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 perform 1 from public.products p
 where p.business_id=p_business_id and p.is_active
  and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)
 order by p.id for update;
 if p_customer_id is not null then
  select name into v_customer_name from public.parties
  where id=p_customer_id and business_id=p_business_id and kind in ('customer','both') and is_active;
  if not found then raise exception 'Customer does not belong to this business'; end if;
 end if;
 select count(*),
  coalesce(sum(round((x->>'quantity')::numeric*(x->>'unit_price')::numeric,2)),0),
  coalesce(sum(round(coalesce((x->>'line_discount')::numeric,0),2)),0)
 into v_item_count,v_gross,v_line_discounts from jsonb_array_elements(p_items) x;
 v_discount:=round(coalesce(p_invoice_discount,0),2);
 if v_line_discounts<0 or v_line_discounts>v_gross then raise exception 'Invalid line discount'; end if;
 if v_discount>v_gross-v_line_discounts then raise exception 'Invoice discount exceeds remaining subtotal'; end if;
 v_total:=round(v_gross-v_line_discounts-v_discount,2);
 if v_paid>v_total then raise exception 'Paid amount exceeds invoice total'; end if;
 if coalesce(p_apply_customer_credit,false) and p_customer_id is not null then
  perform 1 from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id for update;
  select coalesce(sum(amount),0) into v_credit_available from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id;
  v_credit_to_apply:=least(v_credit_available,v_total-v_paid);
 end if;
 insert into public.sales_invoices(
  business_id,invoice_no,customer_id,customer_name_snapshot,invoice_date,
  subtotal,discount,total,paid_total,due_total,status,notes,created_by,customer_credit_applied_total
 ) values (
  p_business_id,v_generated_code,p_customer_id,v_customer_name,coalesce(p_invoice_date,current_date),
  v_gross,v_line_discounts+v_discount,v_total,v_paid+v_credit_to_apply,v_total-v_paid-v_credit_to_apply,'posted',p_notes,auth.uid(),v_credit_to_apply
 ) returning id into v_invoice_id;
 v_credit_remaining:=v_credit_to_apply;
 if v_credit_remaining>0 then
  for v_credit_row in select source_return_id,sum(amount) available from public.customer_credit_ledger where business_id=p_business_id and customer_id=p_customer_id and source_return_id is not null group by source_return_id having sum(amount)>0 order by min(created_at),source_return_id loop
   exit when v_credit_remaining<=0;
   v_credit_take:=least(v_credit_remaining,v_credit_row.available);
   insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,invoice_id,event_type,amount,created_by)
   values(p_business_id,p_customer_id,v_credit_row.source_return_id,v_invoice_id,'invoice_application',-v_credit_take,auth.uid());
   v_credit_remaining:=v_credit_remaining-v_credit_take;
  end loop;
  if v_credit_remaining>0 then raise exception 'Customer credit changed while posting the invoice; retry'; end if;
 end if;
 for v_item in select value from jsonb_array_elements(p_items)
 loop
  v_i:=v_i+1;
  v_qty:=(v_item->>'quantity')::numeric;
  v_price:=(v_item->>'unit_price')::numeric;
  v_item_discount:=coalesce((v_item->>'line_discount')::numeric,0);
  if v_qty<=0 or v_price<0 or v_item_discount<0 then raise exception 'Invalid sale item values'; end if;
  select * into v_product from public.products
  where id=(v_item->>'product_id')::uuid and business_id=p_business_id and is_active for update;
  if not found then raise exception 'Product does not belong to this business'; end if;
  select coalesce(sum(quantity_delta),0) into v_on_hand
  from public.stock_movements where business_id=p_business_id and product_id=v_product.id and stock_bucket='sellable';
  if v_on_hand<v_qty then raise exception 'Insufficient stock for product: % (available %, requested %)',v_product.name,v_on_hand,v_qty; end if;
  v_line_gross:=round(v_qty*v_price,2);
  if v_item_discount>v_line_gross then raise exception 'Line discount exceeds item total'; end if;
  if v_i=v_item_count then
   v_extra_discount:=v_discount-v_discount_used;
  else
   v_extra_discount:=case when v_gross-v_line_discounts=0 then 0
    else least(round(v_discount*(v_line_gross-v_item_discount)/(v_gross-v_line_discounts),2),v_discount-v_discount_used) end;
   v_discount_used:=v_discount_used+v_extra_discount;
  end if;
  v_final_line_discount:=v_item_discount+v_extra_discount;
  v_cost:=v_product.average_cost;
  insert into public.sales_items(
   business_id,invoice_id,product_id,product_name_snapshot,product_code_snapshot,
   warranty_snapshot,warranty_provider_snapshot,quantity,unit_price,line_discount,unit_cost_snapshot,line_total
  ) values (
   p_business_id,v_invoice_id,v_product.id,v_product.name,v_product.code,
   v_product.warranty,v_product.warranty_provider,v_qty,v_price,v_final_line_discount,
   v_cost,round(v_line_gross-v_final_line_discount,2)
  );
  insert into public.stock_movements(
   business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,created_by
  ) values (
   p_business_id,v_product.id,coalesce(p_invoice_date,current_date),'sale',-v_qty,v_cost,'sale',v_invoice_id,auth.uid()
  );
 end loop;
 update public.sales_invoices
 set business_name_snapshot=(select name from public.businesses where id=p_business_id),
     business_phone_snapshot=(select phone from public.businesses where id=p_business_id),
     business_address_snapshot=(select address from public.businesses where id=p_business_id)
 where id=v_invoice_id;
 if v_paid>0 then
  insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by)
  values(p_business_id,p_customer_id,v_invoice_id,'in',v_paid,coalesce(p_invoice_date,current_date),v_method,
   'تحصيل عند إنشاء فاتورة مبيعات',auth.uid()) returning id into v_payment_id;
  if v_method='cash' then
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,created_by,account_method,payment_id)
   values(p_business_id,coalesce(p_invoice_date,current_date),'in','sale_payment',v_paid,p_customer_id,v_invoice_id,
    'تحصيل عند إنشاء فاتورة مبيعات',auth.uid(),'cash',v_payment_id);
  end if;
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'post','sales_invoice',v_invoice_id,
  jsonb_build_object('invoice_no',v_generated_code,'total',v_total,'paid',v_paid,'customer_credit_applied',v_credit_to_apply,'method',v_method));
 return v_invoice_id;
end;
$function$;

revoke all on function public.post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean) from public, anon, authenticated;
grant execute on function public.post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean) to authenticated, service_role;

-- post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)
CREATE OR REPLACE FUNCTION public.post_sale_with_method(p_business_id uuid, p_invoice_no text, p_customer_id uuid, p_invoice_date date, p_items jsonb, p_invoice_discount numeric DEFAULT 0, p_paid_amount numeric DEFAULT 0, p_notes text DEFAULT NULL::text, p_method text DEFAULT 'cash'::text)
 RETURNS uuid
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select public.post_sale_with_method(p_business_id,p_invoice_no,p_customer_id,p_invoice_date,p_items,p_invoice_discount,p_paid_amount,p_notes,p_method,false);
$function$;

revoke all on function public.post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text) from public, anon, authenticated;
grant execute on function public.post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text) to authenticated, service_role;

-- post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)
CREATE OR REPLACE FUNCTION public.post_sales_return(p_business_id uuid, p_return_no text, p_sales_invoice_id uuid, p_items jsonb, p_cash_refund numeric, p_return_date date, p_notes text, p_method text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_return_id uuid; v_generated_code text; v_payment_id uuid;
 v_invoice public.sales_invoices%rowtype;
 v_sale_item public.sales_items%rowtype;
 v_item jsonb;
 v_qty numeric(14,3);
 v_remaining numeric(14,3);
 v_refund numeric(14,2);
 v_total_refund numeric(14,2):=0;
 v_cash_refund numeric(14,2):=coalesce(p_cash_refund,0);
 v_credit_applied numeric(14,2);
 v_method text:=lower(trim(coalesce(p_method,'cash')));
 v_available numeric(14,2):=0; v_unit_price numeric(14,2); v_due_reduced numeric(14,2):=0; v_customer_credit numeric(14,2):=0; v_actual_collected numeric(14,2):=0;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'sales.create') then
  raise exception 'Not authorized to create a sales return';
 end if;
 if v_method not in ('cash','mobile_wallet','bank_transfer','instapay','other') then raise exception 'Choose a supported refund account'; end if;
 v_generated_code:=public.next_operation_code(p_business_id,'sales_return');
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
  raise exception 'At least one returned item is required';
 end if;
 if v_cash_refund<0 then raise exception 'Cash refund cannot be negative'; end if;
 if v_cash_refund>0 then
  if v_method='cash' and not public.has_business_permission(p_business_id,'cash.withdraw') then raise exception 'Not authorized to refund cash'; end if;
  if v_method<>'cash' and not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to refund through this account'; end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));

 select * into v_invoice from public.sales_invoices
 where id=p_sales_invoice_id and business_id=p_business_id for update;
 if not found or v_invoice.status='void' then raise exception 'Valid sales invoice not found'; end if;

 perform 1 from public.products p
 join public.sales_items si on si.business_id=p.business_id and si.product_id=p.id
 join lateral jsonb_array_elements(p_items) j(value)
  on (j.value->>'sales_item_id')::uuid=si.id
 where p.business_id=p_business_id and si.invoice_id=p_sales_invoice_id
 order by p.id for update of p;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::numeric;
  if v_qty<=0 then raise exception 'Return quantity must be positive'; end if;
  select * into v_sale_item from public.sales_items
  where id=(v_item->>'sales_item_id')::uuid and invoice_id=p_sales_invoice_id and business_id=p_business_id
  for update;
  if not found then raise exception 'Returned item is not part of this invoice'; end if;
  v_remaining:=v_sale_item.quantity-v_sale_item.returned_quantity;
  if v_qty>v_remaining then
   raise exception 'Return quantity exceeds the unreturned sold quantity for %',v_sale_item.product_name_snapshot;
  end if;
  if coalesce(v_item->>'condition','') not in ('good','damaged') then
   raise exception 'Return condition must be good or damaged';
  end if;
  v_unit_price:=round(coalesce(nullif(v_item->>'unit_price','')::numeric,(v_sale_item.line_total/v_sale_item.quantity)),2); if v_unit_price<0 then raise exception 'Return unit price cannot be negative'; end if; v_refund:=round(v_unit_price*v_qty,2);
  v_total_refund:=v_total_refund+v_refund;
  update public.sales_items set returned_quantity=returned_quantity+v_qty where id=v_sale_item.id;
 end loop;

 if v_cash_refund>v_total_refund then raise exception 'Cash refund exceeds return value'; end if;
 select coalesce(sum(case when direction='in' then amount else -amount end),0) into v_actual_collected
 from public.payments where business_id=p_business_id and invoice_id=p_sales_invoice_id;
 if v_cash_refund>v_actual_collected then
  raise exception 'Cash refund exceeds the actual amount collected on this invoice. Available to refund: %',v_actual_collected;
 end if;
 v_credit_applied:=least(v_total_refund-v_cash_refund,v_invoice.due_total);
 v_due_reduced:=v_credit_applied;
 v_customer_credit:=v_total_refund-v_cash_refund-v_due_reduced;
 if v_cash_refund>0 then
  if v_method='cash' then select coalesce(balance,0) into v_available from public.cash_balances where business_id=p_business_id; v_available:=coalesce(v_available,0);
  else select coalesce((select sum(case when p.direction='in' then p.amount else -p.amount end) from public.payments p where p.business_id=p_business_id and lower(p.method)=v_method),0)+coalesce((select sum(case when t.destination_method=v_method then t.amount when t.source_method=v_method then -t.amount else 0 end) from public.treasury_transfers t where t.business_id=p_business_id),0)+coalesce((select sum(case when c.direction='in' then c.amount else -c.amount end) from public.cash_transactions c where c.business_id=p_business_id and c.account_method=v_method),0) into v_available;
  end if;
  if coalesce(v_available,0)<v_cash_refund then raise exception 'Insufficient balance in selected refund account. Available: %',coalesce(v_available,0); end if;
 end if;

 insert into public.sales_returns(
  business_id,return_no,sales_invoice_id,customer_id,return_date,refund_total,notes,created_by,status,invoice_due_reduced_total
 ) values (
  p_business_id,v_generated_code,p_sales_invoice_id,v_invoice.customer_id,
  coalesce(p_return_date,current_date),v_total_refund,p_notes,auth.uid(),'posted',v_due_reduced
 ) returning id into v_return_id;
 if v_customer_credit>0 then
  insert into public.customer_credit_ledger(business_id,customer_id,source_return_id,event_type,amount,created_by)
  values(p_business_id,v_invoice.customer_id,v_return_id,'return_credit',v_customer_credit,auth.uid());
 end if;

 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_sale_item from public.sales_items
  where id=(v_item->>'sales_item_id')::uuid and invoice_id=p_sales_invoice_id and business_id=p_business_id;
  v_qty:=(v_item->>'quantity')::numeric;
  v_unit_price:=round(coalesce(nullif(v_item->>'unit_price','')::numeric,(v_sale_item.line_total/v_sale_item.quantity)),2); if v_unit_price<0 then raise exception 'Return unit price cannot be negative'; end if; v_refund:=round(v_unit_price*v_qty,2);
  insert into public.sales_return_items(
   business_id,return_id,sales_item_id,product_id,quantity,condition,unit_price,refund_amount
  ) values(p_business_id,v_return_id,v_sale_item.id,v_sale_item.product_id,v_qty,v_item->>'condition',v_unit_price,v_refund);

  if v_item->>'condition'='good' then
   insert into public.stock_movements(
    business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,created_by,stock_bucket
   ) values(
    p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
    'customer_return_good',v_qty,v_sale_item.unit_cost_snapshot,'sales_return',v_return_id,auth.uid(),'sellable'
   );
  else
   insert into public.stock_movements(
    business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,notes,created_by,stock_bucket
   ) values(
    p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
    'customer_return_damaged',v_qty,v_sale_item.unit_cost_snapshot,'sales_return',v_return_id,
    'مرتجع عميل تالف',auth.uid(),'damaged'
   );
  end if;
 end loop;

 update public.sales_invoices
 set paid_total=paid_total-v_cash_refund,
     due_total=due_total-v_credit_applied,
     status=case
      when not exists(select 1 from public.sales_items si where si.invoice_id=p_sales_invoice_id
        and si.business_id=p_business_id and si.returned_quantity<si.quantity) then 'returned'
      else 'partially_returned' end
 where id=p_sales_invoice_id and business_id=p_business_id;

 if v_cash_refund>0 then
  insert into public.payments(
   business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by,sales_return_id
  ) values(
   p_business_id,v_invoice.customer_id,p_sales_invoice_id,'out',v_cash_refund,
   coalesce(p_return_date,current_date),v_method,'رد مبلغ لمرتجع مبيعات',auth.uid(),v_return_id
  ) returning id into v_payment_id;
  if v_method='cash' then insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,sales_return_id,account_method,payment_id) values(p_business_id,coalesce(p_return_date,current_date),'out','customer_refund',v_cash_refund,v_invoice.customer_id,p_sales_invoice_id,'رد مبلغ لمرتجع مبيعات',p_notes,auth.uid(),v_return_id,'cash',v_payment_id); end if;
 end if;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'return','sales_return',v_return_id,
  jsonb_build_object('invoice_id',p_sales_invoice_id,'refund_total',v_total_refund,
   'cash_refund',v_cash_refund,'invoice_due_reduced',v_due_reduced,'customer_credit_created',v_customer_credit));
 return v_return_id;
end;
$function$;

revoke all on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text) from public, anon, authenticated;
grant execute on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text) to authenticated, service_role;

-- post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)
CREATE OR REPLACE FUNCTION public.post_sales_return(p_business_id uuid, p_return_no text, p_sales_invoice_id uuid, p_items jsonb, p_cash_refund numeric DEFAULT 0, p_return_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_return_id uuid; v_generated_code text;
 v_invoice public.sales_invoices%rowtype;
 v_sale_item public.sales_items%rowtype;
 v_item jsonb;
 v_qty numeric(14,3);
 v_remaining numeric(14,3);
 v_refund numeric(14,2);
 v_total_refund numeric(14,2):=0;
 v_cash_refund numeric(14,2):=coalesce(p_cash_refund,0);
 v_credit_applied numeric(14,2);
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'sales.create') then
  raise exception 'Not authorized to create a sales return';
 end if;
 v_generated_code:=public.next_operation_code(p_business_id,'sales_return');
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
  raise exception 'At least one returned item is required';
 end if;
 if v_cash_refund<0 then raise exception 'Cash refund cannot be negative'; end if;
 if v_cash_refund>0 then
  if not public.has_business_permission(p_business_id,'cash.withdraw') then
   raise exception 'Not authorized to refund cash';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 end if;

 select * into v_invoice from public.sales_invoices
 where id=p_sales_invoice_id and business_id=p_business_id for update;
 if not found or v_invoice.status='void' then raise exception 'Valid sales invoice not found'; end if;

 perform 1 from public.products p
 join public.sales_items si on si.business_id=p.business_id and si.product_id=p.id
 join lateral jsonb_array_elements(p_items) j(value)
  on (j.value->>'sales_item_id')::uuid=si.id
 where p.business_id=p_business_id and si.invoice_id=p_sales_invoice_id
 order by p.id for update of p;

 for v_item in select value from jsonb_array_elements(p_items) loop
  v_qty:=(v_item->>'quantity')::numeric;
  if v_qty<=0 then raise exception 'Return quantity must be positive'; end if;
  select * into v_sale_item from public.sales_items
  where id=(v_item->>'sales_item_id')::uuid and invoice_id=p_sales_invoice_id and business_id=p_business_id
  for update;
  if not found then raise exception 'Returned item is not part of this invoice'; end if;
  v_remaining:=v_sale_item.quantity-v_sale_item.returned_quantity;
  if v_qty>v_remaining then
   raise exception 'Return quantity exceeds the unreturned sold quantity for %',v_sale_item.product_name_snapshot;
  end if;
  if coalesce(v_item->>'condition','') not in ('good','damaged') then
   raise exception 'Return condition must be good or damaged';
  end if;
  v_refund:=round((v_sale_item.line_total/v_sale_item.quantity)*v_qty,2);
  v_total_refund:=v_total_refund+v_refund;
  update public.sales_items set returned_quantity=returned_quantity+v_qty where id=v_sale_item.id;
 end loop;

 if v_cash_refund>v_total_refund then raise exception 'Cash refund exceeds return value'; end if;
 if v_cash_refund>v_invoice.paid_total then raise exception 'Cash refund cannot exceed the amount already collected on this invoice'; end if;
 v_credit_applied:=v_total_refund-v_cash_refund;
 if v_credit_applied>v_invoice.due_total then
  raise exception 'Cash refund must cover the portion not offset against the outstanding balance';
 end if;
 if v_cash_refund>0 and not public.has_business_permission(p_business_id,'cash.withdraw') then
  raise exception 'Not authorized to refund cash';
 end if;
 if v_cash_refund>0 then
  if v_cash_refund>coalesce((select sum(case when direction='in' then amount else -amount end)
    from public.cash_transactions where business_id=p_business_id),0) then
   raise exception 'Insufficient cash balance for this customer refund';
  end if;
 end if;

 insert into public.sales_returns(
  business_id,return_no,sales_invoice_id,customer_id,return_date,refund_total,notes,created_by,status
 ) values (
  p_business_id,v_generated_code,p_sales_invoice_id,v_invoice.customer_id,
  coalesce(p_return_date,current_date),v_total_refund,p_notes,auth.uid(),'posted'
 ) returning id into v_return_id;

 for v_item in select value from jsonb_array_elements(p_items) loop
  select * into v_sale_item from public.sales_items
  where id=(v_item->>'sales_item_id')::uuid and invoice_id=p_sales_invoice_id and business_id=p_business_id;
  v_qty:=(v_item->>'quantity')::numeric;
  v_refund:=round((v_sale_item.line_total/v_sale_item.quantity)*v_qty,2);
  insert into public.sales_return_items(
   business_id,return_id,sales_item_id,product_id,quantity,condition,refund_amount
  ) values(p_business_id,v_return_id,v_sale_item.id,v_sale_item.product_id,v_qty,v_item->>'condition',v_refund);

  if v_item->>'condition'='good' then
   insert into public.stock_movements(
    business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,created_by,stock_bucket
   ) values(
    p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
    'customer_return_good',v_qty,v_sale_item.unit_cost_snapshot,'sales_return',v_return_id,auth.uid(),'sellable'
   );
  else
   insert into public.stock_movements(
    business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,notes,created_by,stock_bucket
   ) values(
    p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
    'customer_return_damaged',v_qty,v_sale_item.unit_cost_snapshot,'sales_return',v_return_id,
    'مرتجع عميل تالف',auth.uid(),'damaged'
   );
  end if;
 end loop;

 update public.sales_invoices
 set paid_total=paid_total-v_cash_refund,
     due_total=due_total-v_credit_applied,
     status=case
      when not exists(select 1 from public.sales_items si where si.invoice_id=p_sales_invoice_id
        and si.business_id=p_business_id and si.returned_quantity<si.quantity) then 'returned'
      else 'partially_returned' end
 where id=p_sales_invoice_id and business_id=p_business_id;

 if v_cash_refund>0 then
  insert into public.payments(
   business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by,sales_return_id
  ) values(
   p_business_id,v_invoice.customer_id,p_sales_invoice_id,'out',v_cash_refund,
   coalesce(p_return_date,current_date),'cash','رد نقدي لمرتجع مبيعات',auth.uid(),v_return_id
  );
  insert into public.cash_transactions(
   business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,sales_return_id
  ) values(
   p_business_id,coalesce(p_return_date,current_date),'out','customer_refund',
   v_cash_refund,v_invoice.customer_id,p_sales_invoice_id,'رد نقدي لمرتجع مبيعات',
   p_notes,auth.uid(),v_return_id
  );
 end if;

 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'return','sales_return',v_return_id,
  jsonb_build_object('invoice_id',p_sales_invoice_id,'refund_total',v_total_refund,
   'cash_refund',v_cash_refund,'credit_applied',v_credit_applied));
 return v_return_id;
end;
$function$;

revoke all on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text) from public, anon, authenticated;
grant execute on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text) to authenticated, service_role;

-- post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)
CREATE OR REPLACE FUNCTION public.post_stock_adjustment(p_business_id uuid, p_product_id uuid, p_quantity_delta numeric, p_reason text, p_movement_date date DEFAULT CURRENT_DATE, p_unit_cost numeric DEFAULT NULL::numeric)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_product public.products%rowtype;
 v_on_hand numeric(14,3);
 v_new_qty numeric(14,3);
 v_cost numeric(14,4);
 v_new_avg numeric(14,2);
 v_type text;
 v_id uuid := gen_random_uuid();
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'inventory.create') then
  raise exception 'Not authorized to adjust inventory';
 end if;
 if p_quantity_delta is null or p_quantity_delta=0 or coalesce(trim(p_reason),'')='' then
  raise exception 'A non-zero quantity and reason are required';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||p_product_id::text,0));
 select * into v_product from public.products
 where id=p_product_id and business_id=p_business_id and is_active=true for update;
 if not found then raise exception 'Product not found in this business'; end if;
 select coalesce(sum(quantity_delta),0) into v_on_hand
 from public.stock_movements where business_id=p_business_id and product_id=p_product_id and stock_bucket='sellable';
 v_new_qty:=v_on_hand+p_quantity_delta;
 if v_new_qty<0 then raise exception 'Stock adjustment cannot make inventory negative'; end if;
 if p_quantity_delta>0 then
  v_type:='adjustment_in'; v_cost:=coalesce(p_unit_cost,v_product.average_cost);
  if v_cost<0 then raise exception 'Unit cost cannot be negative'; end if;
  v_new_avg:=case when v_new_qty=0 then 0
   else round(((v_on_hand*v_product.average_cost)+(p_quantity_delta*v_cost))/v_new_qty,2) end;
 else
  v_type:='adjustment_out'; v_cost:=v_product.average_cost; v_new_avg:=v_product.average_cost;
 end if;
 insert into public.stock_movements(
  id,business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,notes,created_by,stock_bucket
 ) values(
  v_id,p_business_id,p_product_id,coalesce(p_movement_date,current_date),v_type,p_quantity_delta,
  v_cost,'manual_adjustment',v_id,trim(p_reason),auth.uid(),'sellable'
 );
 insert into public.stock_adjustment_cost_snapshots(business_id,movement_id,product_id,average_cost_before)
 values(p_business_id,v_id,p_product_id,v_product.average_cost);
 update public.products set average_cost=v_new_avg,updated_at=now() where id=p_product_id and business_id=p_business_id;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'stock_adjustment','stock_movement',v_id,
 jsonb_build_object('product_id',p_product_id,'quantity_delta',p_quantity_delta,'reason',p_reason,'new_balance',v_new_qty));
 return v_id;
end;
$function$;

revoke all on function public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric) from public, anon, authenticated;
grant execute on function public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric) to authenticated, service_role;

-- post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)
CREATE OR REPLACE FUNCTION public.post_stock_condition_transfer(p_business_id uuid, p_product_id uuid, p_quantity numeric, p_from_bucket text, p_to_bucket text, p_reason text, p_movement_date date DEFAULT CURRENT_DATE)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_product public.products%rowtype;
 v_available numeric(14,3);
 v_transfer_id uuid:=gen_random_uuid();
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'inventory.create') then
  raise exception 'Not authorized to transfer stock condition';
 end if;
 if p_from_bucket not in ('sellable','damaged') or p_to_bucket not in ('sellable','damaged')
   or p_from_bucket=p_to_bucket then
  raise exception 'Invalid stock condition transfer';
 end if;
 if p_quantity is null or p_quantity<=0 or coalesce(trim(p_reason),'')='' then
  raise exception 'A positive quantity and reason are required';
 end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text||p_product_id::text,0));
 select * into v_product from public.products
 where id=p_product_id and business_id=p_business_id and is_active=true for update;
 if not found then raise exception 'Product not found in this business'; end if;
 select coalesce(sum(quantity_delta),0) into v_available from public.stock_movements
 where business_id=p_business_id and product_id=p_product_id and stock_bucket=p_from_bucket;
 if v_available<p_quantity then
  raise exception 'Insufficient quantity in the selected stock condition (available %, requested %)',v_available,p_quantity;
 end if;
 insert into public.stock_movements(
  business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
  source_type,source_id,notes,created_by,stock_bucket
 ) values (
  p_business_id,p_product_id,coalesce(p_movement_date,current_date),
  'condition_transfer_out',-p_quantity,v_product.average_cost,
  'condition_transfer',v_transfer_id,trim(p_reason)||' (من '||p_from_bucket||')',auth.uid(),p_from_bucket
 ),(
  p_business_id,p_product_id,coalesce(p_movement_date,current_date),
  'condition_transfer_in',p_quantity,v_product.average_cost,
  'condition_transfer',v_transfer_id,trim(p_reason)||' (إلى '||p_to_bucket||')',auth.uid(),p_to_bucket
 );
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'stock_condition_transfer','stock_movement',v_transfer_id,
  jsonb_build_object('product_id',p_product_id,'quantity',p_quantity,
   'from_bucket',p_from_bucket,'to_bucket',p_to_bucket,'reason',p_reason));
 return v_transfer_id;
end;
$function$;

revoke all on function public.post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date) from public, anon, authenticated;
grant execute on function public.post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date) to authenticated, service_role;

-- receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)
CREATE OR REPLACE FUNCTION public.receive_supplier_credit(p_business_id uuid, p_supplier_id uuid, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
 v_supplier public.parties%rowtype; v_available_credit numeric(14,2):=0; v_payment_id uuid;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'purchases.view') then raise exception 'Not authorized to receive supplier credit'; end if;
 if p_amount is null or p_amount<=0 then raise exception 'Receipt amount must be positive'; end if;
 p_method:=lower(btrim(coalesce(p_method,'cash')));
 if p_method not in ('cash','bank_transfer','instapay','mobile_wallet','other') then raise exception 'Unsupported receipt method'; end if;
 if p_method='cash' then
  if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to receive cash'; end if;
 elsif not public.has_business_permission(p_business_id,'payments.create') then raise exception 'Not authorized to receive this payment method'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_supplier from public.parties where id=p_supplier_id and business_id=p_business_id for update;
 if not found or v_supplier.kind not in ('supplier','both') then raise exception 'Supplier not found in this business'; end if;
 if not v_supplier.is_active then raise exception 'Cannot receive credit from an archived supplier'; end if;
 select greatest(0,-coalesce(supplier_net_balance,0)) into v_available_credit from public.party_account_balances where business_id=p_business_id and party_id=p_supplier_id;
 v_available_credit:=coalesce(v_available_credit,0);
 if p_amount>v_available_credit then raise exception 'Receipt exceeds available supplier credit. Available: %, requested: %',v_available_credit,p_amount; end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by)
 values(p_business_id,p_supplier_id,null,'supplier','in',round(p_amount,2),coalesce(p_payment_date,current_date),p_method,nullif(btrim(p_reference),''),'استلام رصيد دائن من المورد. '||coalesce(nullif(btrim(p_notes),''),''),auth.uid()) returning id into v_payment_id;
 if p_method='cash' then
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by,payment_id,account_method)
  values(p_business_id,coalesce(p_payment_date,current_date),'in','other',round(p_amount,2),p_supplier_id,null,'استلام رصيد دائن من مورد',nullif(btrim(p_notes),''),auth.uid(),v_payment_id,'cash');
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'receive_supplier_credit','payment',v_payment_id,jsonb_build_object('supplier_id',p_supplier_id,'amount',round(p_amount,2),'method',p_method,'available_before',v_available_credit));
 return v_payment_id;
end;$function$;

revoke all on function public.receive_supplier_credit(uuid,uuid,numeric,date,text,text,text) from public, anon, authenticated;
grant execute on function public.receive_supplier_credit(uuid,uuid,numeric,date,text,text,text) to authenticated, service_role;

commit;

-- Review notes:
-- * 10 signatures include both post_sale_with_method overloads and both post_sales_return overloads.
-- * The 9-argument post_sale_with_method overload is a compatibility wrapper to the 10-argument function.
-- * The 7-argument post_sales_return overload is retained for existing callers; it does not accept a refund method.
-- * Posting functions use next_operation_code where required and rely on the helper/trigger stage.
-- * Functional tests must cover invoice totals/discount allocation, stock availability, damaged vs sellable returns,
--   customer credit application/payout, supplier credit/returns, rollback, and repeated submissions.
-- This file has not been executed on Test or Production.
