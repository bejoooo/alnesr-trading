do $$
declare
 v_def text;
 v_old text := $old$status=case
      when not exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity<si.quantity) then 'returned'
      when exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity>0) then 'partially_returned'
      when due_total+v_credit_applied=0 then 'paid'
      when paid_total+v_cash_refund>0 then 'partially_paid'
      else 'posted' end$old$;
 v_new text := $new$status=case
      when not exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity<si.quantity) then 'returned'
      when exists(select 1 from public.sales_items si where si.business_id=p_business_id
        and si.invoice_id=v_invoice.id and si.returned_quantity>0) then 'partially_returned'
      else 'posted' end$new$;
begin
 select pg_get_functiondef('public.owner_remove_sales_return(uuid,uuid)'::regprocedure) into v_def;
 if position(v_old in v_def)>0 then
  execute replace(v_def,v_old,v_new);
 elsif position('when due_total+v_credit_applied=0 then ''paid''' in v_def)>0 then
  raise exception 'Unexpected old status branch remains';
 elsif position('else ''posted'' end' in v_def)=0 then
  raise exception 'Sales return status branch is not in expected safe form';
 end if;
end $$;