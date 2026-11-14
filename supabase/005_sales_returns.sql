-- Al Nesr Trading — atomic sales returns
-- Apply after 004_tenant_integrity.sql on a TEST Supabase project first.

create or replace function public.post_sales_return(
  p_business_id uuid,
  p_return_no text,
  p_sales_invoice_id uuid,
  p_items jsonb,
  p_cash_refund numeric default 0,
  p_return_date date default current_date,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_return_id uuid;
  v_invoice public.sales_invoices%rowtype;
  v_sale_item public.sales_items%rowtype;
  v_item jsonb;
  v_qty numeric(14,3);
  v_remaining numeric(14,3);
  v_refund numeric(14,2);
  v_total_refund numeric(14,2) := 0;
  v_cash_refund numeric(14,2) := coalesce(p_cash_refund,0);
  v_credit_applied numeric(14,2);
  v_all_returned boolean;
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id,'sales.create') then
    raise exception 'Not authorized to create a sales return';
  end if;
  if coalesce(trim(p_return_no),'')='' then raise exception 'Return number is required'; end if;
  if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'At least one returned item is required';
  end if;
  if v_cash_refund<0 then raise exception 'Cash refund cannot be negative'; end if;

  select * into v_invoice
  from public.sales_invoices
  where id=p_sales_invoice_id and business_id=p_business_id
  for update;
  if not found or v_invoice.status='void' then raise exception 'Valid sales invoice not found'; end if;

  -- Lock and validate each sold line. Repeated item IDs in the JSON are safe:
  -- the returned quantity is updated inside the loop before the next occurrence.
  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_qty := (v_item->>'quantity')::numeric;
    if v_qty<=0 then raise exception 'Return quantity must be positive'; end if;
    select * into v_sale_item from public.sales_items
    where id=(v_item->>'sales_item_id')::uuid
      and invoice_id=p_sales_invoice_id and business_id=p_business_id
    for update;
    if not found then raise exception 'Returned item is not part of this invoice'; end if;

    v_remaining := v_sale_item.quantity-v_sale_item.returned_quantity;
    if v_qty>v_remaining then
      raise exception 'Return quantity exceeds the unreturned sold quantity for %',v_sale_item.product_name_snapshot;
    end if;
    if coalesce(v_item->>'condition','') not in ('good','damaged') then
      raise exception 'Return condition must be good or damaged';
    end if;
    v_refund := round((v_sale_item.line_total/v_sale_item.quantity)*v_qty,2);
    v_total_refund := v_total_refund+v_refund;
    update public.sales_items
      set returned_quantity=returned_quantity+v_qty
    where id=v_sale_item.id;
  end loop;

  if v_cash_refund>v_total_refund then raise exception 'Cash refund exceeds return value'; end if;
  if v_cash_refund>v_invoice.paid_total then
    raise exception 'Cash refund cannot exceed the amount already collected on this invoice';
  end if;
  v_credit_applied := v_total_refund-v_cash_refund;
  if v_credit_applied>v_invoice.due_total then
    raise exception 'Cash refund must cover the portion not offset against the outstanding balance';
  end if;
  if v_cash_refund>0 and not public.has_business_permission(p_business_id,'cash.withdraw') then
    raise exception 'Not authorized to refund cash';
  end if;
  if v_cash_refund>0 then perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0)); end if;
  if v_cash_refund>coalesce((select sum(case when direction='in' then amount else -amount end) from public.cash_transactions where business_id=p_business_id),0) then
    raise exception 'Insufficient cash balance for this customer refund';
  end if;

  insert into public.sales_returns(
    business_id,return_no,sales_invoice_id,customer_id,return_date,refund_total,notes,created_by
  ) values (
    p_business_id,trim(p_return_no),p_sales_invoice_id,v_invoice.customer_id,
    coalesce(p_return_date,current_date),v_total_refund,p_notes,auth.uid()
  ) returning id into v_return_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    select * into v_sale_item from public.sales_items
    where id=(v_item->>'sales_item_id')::uuid
      and invoice_id=p_sales_invoice_id and business_id=p_business_id;
    v_qty := (v_item->>'quantity')::numeric;
    v_refund := round((v_sale_item.line_total/v_sale_item.quantity)*v_qty,2);

    insert into public.sales_return_items(
      business_id,return_id,sales_item_id,product_id,quantity,condition,refund_amount
    ) values (
      p_business_id,v_return_id,v_sale_item.id,v_sale_item.product_id,v_qty,
      v_item->>'condition',v_refund
    );

    if v_item->>'condition'='good' then
      insert into public.stock_movements(
        business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,
        source_type,source_id,created_by
      ) values (
        p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
        'customer_return_good',v_qty,v_sale_item.unit_cost_snapshot,
        'sales_return',v_return_id,auth.uid()
      );
    end if;
  end loop;

  update public.sales_invoices
  set paid_total=paid_total-v_cash_refund,
      due_total=due_total-v_credit_applied,
      status=case
        when not exists (
          select 1 from public.sales_items si
          where si.invoice_id=p_sales_invoice_id
            and si.business_id=p_business_id
            and si.returned_quantity<si.quantity
        ) then 'returned'
        else 'partially_returned'
      end
  where id=p_sales_invoice_id;

  if v_cash_refund>0 then
    insert into public.payments(
      business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by
    ) values (
      p_business_id,v_invoice.customer_id,p_sales_invoice_id,'out',v_cash_refund,
      coalesce(p_return_date,current_date),'cash','رد نقدي لمرتجع مبيعات',auth.uid()
    );
    insert into public.cash_transactions(
      business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,notes,created_by
    ) values (
      p_business_id,coalesce(p_return_date,current_date),'out','customer_refund',
      v_cash_refund,v_invoice.customer_id,p_sales_invoice_id,'رد نقدي لمرتجع مبيعات',p_notes,auth.uid()
    );
  end if;

  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'return','sales_return',v_return_id,
    jsonb_build_object('invoice_id',p_sales_invoice_id,'refund_total',v_total_refund,
      'cash_refund',v_cash_refund,'credit_applied',v_credit_applied));
  return v_return_id;
end;
$$;

revoke all on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text) from public, anon;
grant execute on function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text) to authenticated;
