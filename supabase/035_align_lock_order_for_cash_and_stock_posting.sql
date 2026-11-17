CREATE OR REPLACE FUNCTION public.post_purchase(p_business_id uuid, p_invoice_no text, p_supplier_id uuid, p_invoice_date date, p_items jsonb, p_supplier_discount numeric DEFAULT 0, p_paid_amount numeric DEFAULT 0, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
 v_invoice_id uuid; v_item jsonb; v_product public.products%rowtype;
 v_qty numeric(14,3); v_price numeric(14,2); v_subtotal numeric(14,2):=0;
 v_discount numeric(14,2); v_total numeric(14,2); v_line_gross numeric(14,2);
 v_line_discount numeric(14,2); v_discount_used numeric(14,2):=0;
 v_item_count integer; v_i integer:=0; v_on_hand numeric(14,3);
 v_new_avg numeric(14,2); v_supplier_name text;
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'purchases.create') then
   raise exception 'Not authorized to create purchases';
 end if;
 if coalesce(trim(p_invoice_no),'')='' then raise exception 'Invoice number is required'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
   raise exception 'At least one purchase item is required';
 end if;
 if coalesce(p_supplier_discount,0)<0 or coalesce(p_paid_amount,0)<0 then
   raise exception 'Discount and paid amount cannot be negative';
 end if;
 if coalesce(p_paid_amount,0)>0 then
  if not public.has_business_permission(p_business_id,'cash.create') then
   raise exception 'Not authorized to record the cash payment';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 end if;
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
 if p_paid_amount>v_total then raise exception 'Paid amount exceeds invoice total'; end if;
 insert into public.purchase_invoices(
   business_id,invoice_no,supplier_id,supplier_name_snapshot,invoice_date,
   subtotal,supplier_discount,total,paid_total,due_total,status,notes,created_by
 ) values (
   p_business_id,trim(p_invoice_no),p_supplier_id,v_supplier_name,coalesce(p_invoice_date,current_date),
   v_subtotal,v_discount,v_total,coalesce(p_paid_amount,0),v_total-coalesce(p_paid_amount,0),
   case when coalesce(p_paid_amount,0)=0 then 'posted' when p_paid_amount=v_total then 'paid' else 'partially_paid' end,
   p_notes,auth.uid()
 ) returning id into v_invoice_id;
 for v_item in select value from jsonb_array_elements(p_items)
 loop
   v_i:=v_i+1;
   if not (v_item ? 'product_id') then raise exception 'Missing product_id'; end if;
   v_qty:=(v_item->>'quantity')::numeric; v_price:=(v_item->>'unit_price')::numeric;
   if v_qty<=0 or v_price<0 then raise exception 'Invalid purchase quantity or price'; end if;
   select * into v_product from public.products
   where id=(v_item->>'product_id')::uuid and business_id=p_business_id and is_active
   for update;
   if not found then raise exception 'Product does not belong to this business or is inactive'; end if;

   insert into public.purchase_invoice_cost_snapshots(business_id,invoice_id,product_id,average_cost_before)
   values(p_business_id,v_invoice_id,v_product.id,v_product.average_cost)
   on conflict(invoice_id,product_id) do nothing;

   v_line_gross:=round(v_qty*v_price,2);
   if v_i=v_item_count then v_line_discount:=v_discount-v_discount_used;
   else v_line_discount:=case when v_subtotal=0 then 0 else least(round(v_discount*v_line_gross/v_subtotal,2),v_discount-v_discount_used) end;
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
 if coalesce(p_paid_amount,0)>0 then
   if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to record the cash payment'; end if;
   if coalesce((select sum(case when direction='in' then amount else -amount end) from public.cash_transactions where business_id=p_business_id),0)<p_paid_amount then
     raise exception 'Insufficient cash balance for this supplier payment';
   end if;
   insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by)
   values(p_business_id,p_supplier_id,v_invoice_id,'out',p_paid_amount,coalesce(p_invoice_date,current_date),'cash','دفعة عند إنشاء فاتورة مشتريات',auth.uid());
   insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,created_by)
   values(p_business_id,coalesce(p_invoice_date,current_date),'out','purchase_payment',p_paid_amount,p_supplier_id,v_invoice_id,'سداد عند إنشاء فاتورة مشتريات',auth.uid());
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'post','purchase_invoice',v_invoice_id,jsonb_build_object('invoice_no',p_invoice_no,'total',v_total,'paid',coalesce(p_paid_amount,0)));
 return v_invoice_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.post_sale(p_business_id uuid, p_invoice_no text, p_customer_id uuid, p_invoice_date date, p_items jsonb, p_invoice_discount numeric DEFAULT 0, p_paid_amount numeric DEFAULT 0, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_invoice_id uuid;
  v_item jsonb;
  v_product public.products%rowtype;
  v_qty numeric(14,3);
  v_price numeric(14,2);
  v_item_discount numeric(14,2);
  v_gross numeric(14,2) := 0;
  v_line_discounts numeric(14,2) := 0;
  v_discount numeric(14,2);
  v_total numeric(14,2);
  v_line_gross numeric(14,2);
  v_extra_discount numeric(14,2);
  v_final_line_discount numeric(14,2);
  v_discount_used numeric(14,2) := 0;
  v_item_count integer;
  v_i integer := 0;
  v_on_hand numeric(14,3);
  v_customer_name text := 'عميل نقدي';
  v_cost numeric(14,4);
begin
  if auth.uid() is null or not public.has_business_permission(p_business_id, 'sales.create') then
    raise exception 'Not authorized to create sales';
  end if;
  if coalesce(trim(p_invoice_no),'') = '' then raise exception 'Invoice number is required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one sale item is required';
  end if;
  if coalesce(p_invoice_discount,0) < 0 or coalesce(p_paid_amount,0) < 0 then
    raise exception 'Discount and paid amount cannot be negative';
  end if;
  if coalesce(p_paid_amount,0)>0 then
    if not public.has_business_permission(p_business_id,'cash.create') then
      raise exception 'Not authorized to record the cash receipt';
    end if;
    perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  end if;
  perform 1 from public.products p
  where p.business_id=p_business_id
    and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)
  order by p.id for update;
  if p_customer_id is not null then
    select name into v_customer_name from public.parties
    where id=p_customer_id and business_id=p_business_id and kind in ('customer','both');
    if not found then raise exception 'Customer does not belong to this business'; end if;
  end if;

  -- Match the per-line cent rounding used when inserting sales_items so the
  -- invoice total always reconciles with the sum of its stored lines.
  select count(*),
    coalesce(sum(round((x->>'quantity')::numeric * (x->>'unit_price')::numeric,2)),0),
    coalesce(sum(round(coalesce((x->>'line_discount')::numeric,0),2)),0)
  into v_item_count,v_gross,v_line_discounts
  from jsonb_array_elements(p_items) x;

  v_discount := round(coalesce(p_invoice_discount,0),2);
  if v_line_discounts < 0 or v_line_discounts > v_gross then raise exception 'Invalid line discount'; end if;
  if v_discount > v_gross-v_line_discounts then raise exception 'Invoice discount exceeds remaining subtotal'; end if;
  v_total := round(v_gross-v_line_discounts-v_discount,2);
  if p_paid_amount > v_total then raise exception 'Paid amount exceeds invoice total'; end if;

  insert into public.sales_invoices(
    business_id,invoice_no,customer_id,customer_name_snapshot,invoice_date,
    subtotal,discount,total,paid_total,due_total,status,notes,created_by
  ) values (
    p_business_id,trim(p_invoice_no),p_customer_id,v_customer_name,coalesce(p_invoice_date,current_date),
    v_gross,v_line_discounts+v_discount,v_total,coalesce(p_paid_amount,0),
    v_total-coalesce(p_paid_amount,0),
    case when coalesce(p_paid_amount,0)=0 then 'posted'
         when p_paid_amount=v_total then 'posted' else 'posted' end,
    p_notes,auth.uid()
  ) returning id into v_invoice_id;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_i := v_i + 1;
    v_qty := (v_item->>'quantity')::numeric;
    v_price := (v_item->>'unit_price')::numeric;
    v_item_discount := coalesce((v_item->>'line_discount')::numeric,0);
    if v_qty <= 0 or v_price < 0 or v_item_discount < 0 then raise exception 'Invalid sale item values'; end if;

    select * into v_product from public.products
    where id=(v_item->>'product_id')::uuid and business_id=p_business_id
    for update;
    if not found then raise exception 'Product does not belong to this business'; end if;

    select coalesce(sum(quantity_delta),0) into v_on_hand
    from public.stock_movements where business_id=p_business_id and product_id=v_product.id;
    if v_on_hand < v_qty then
      raise exception 'Insufficient stock for product: % (available %, requested %)',v_product.name,v_on_hand,v_qty;
    end if;

    v_line_gross := round(v_qty*v_price,2);
    if v_item_discount > v_line_gross then raise exception 'Line discount exceeds item total'; end if;
    if v_i = v_item_count then
      v_extra_discount := v_discount-v_discount_used;
    else
      v_extra_discount := case when v_gross-v_line_discounts=0 then 0
        else least(round(v_discount*(v_line_gross-v_item_discount)/(v_gross-v_line_discounts),2), v_discount-v_discount_used) end;
      v_discount_used := v_discount_used+v_extra_discount;
    end if;
    v_final_line_discount := v_item_discount+v_extra_discount;
    v_cost := v_product.average_cost;

    insert into public.sales_items(
      business_id,invoice_id,product_id,product_name_snapshot,product_code_snapshot,
      warranty_snapshot,warranty_provider_snapshot,quantity,unit_price,line_discount,
      unit_cost_snapshot,line_total
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

  if coalesce(p_paid_amount,0)>0 then
    if not public.has_business_permission(p_business_id,'cash.create') then
      raise exception 'Not authorized to record the cash receipt';
    end if;
    insert into public.payments(business_id,party_id,invoice_id,direction,amount,payment_date,method,notes,created_by)
    values(p_business_id,p_customer_id,v_invoice_id,'in',p_paid_amount,coalesce(p_invoice_date,current_date),'cash','تحصيل عند إنشاء فاتورة مبيعات',auth.uid());
    insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,reason,created_by)
    values(p_business_id,coalesce(p_invoice_date,current_date),'in','sale_payment',p_paid_amount,p_customer_id,v_invoice_id,'تحصيل عند إنشاء فاتورة مبيعات',auth.uid());
  end if;

  insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
  values(p_business_id,auth.uid(),'post','sales_invoice',v_invoice_id,
    jsonb_build_object('invoice_no',p_invoice_no,'total',v_total,'paid',coalesce(p_paid_amount,0)));
  return v_invoice_id;
end;
$function$
;

CREATE OR REPLACE FUNCTION public.post_sales_return(p_business_id uuid, p_return_no text, p_sales_invoice_id uuid, p_items jsonb, p_cash_refund numeric DEFAULT 0, p_return_date date DEFAULT CURRENT_DATE, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_return_id uuid;
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
 if coalesce(trim(p_return_no),'')='' then raise exception 'Return number is required'; end if;
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
  p_business_id,trim(p_return_no),p_sales_invoice_id,v_invoice.customer_id,
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
    business_id,product_id,movement_date,movement_type,quantity_delta,unit_cost,source_type,source_id,created_by
   ) values(
    p_business_id,v_sale_item.product_id,coalesce(p_return_date,current_date),
    'customer_return_good',v_qty,v_sale_item.unit_cost_snapshot,'sales_return',v_return_id,auth.uid()
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
    perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
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
