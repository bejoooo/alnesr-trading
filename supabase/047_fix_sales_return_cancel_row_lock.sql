do $$
declare
 v_def text;
 v_old text := $old$ for v_item in
  select sri.sales_item_id,sum(sri.quantity) as return_qty,si.returned_quantity
  from public.sales_return_items sri
  join public.sales_items si on si.id=sri.sales_item_id and si.business_id=sri.business_id
  where sri.business_id=p_business_id and sri.return_id=p_return_id
  group by sri.sales_item_id,si.returned_quantity
  for update of si
 loop$old$;
 v_new text := $new$ perform 1 from public.sales_items si
  where si.business_id=p_business_id
   and si.id in (select sri.sales_item_id from public.sales_return_items sri
    where sri.business_id=p_business_id and sri.return_id=p_return_id)
  order by si.id for update;
 for v_item in
  select sri.sales_item_id,sum(sri.quantity) as return_qty,max(si.returned_quantity) as returned_quantity
  from public.sales_return_items sri
  join public.sales_items si on si.id=sri.sales_item_id and si.business_id=sri.business_id
  where sri.business_id=p_business_id and sri.return_id=p_return_id
  group by sri.sales_item_id
 loop$new$;
begin
 select pg_get_functiondef('public.owner_remove_sales_return(uuid,uuid)'::regprocedure) into v_def;
 if position(v_old in v_def)>0 then
  execute replace(v_def,v_old,v_new);
 elsif position('max(si.returned_quantity) as returned_quantity' in v_def)=0
    or position('order by si.id for update' in v_def)=0 then
  raise exception 'Sales return cancellation function has an unexpected definition';
 end if;
end $$;