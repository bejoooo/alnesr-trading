do $$
declare
 v_def text;
 v_old_lock text := $old$where p.business_id=p_business_id
    and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)$old$;
 v_new_lock text := $new$where p.business_id=p_business_id
    and p.is_active
    and p.id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x)$new$;
 v_old_customer text := $old$where id=p_customer_id and business_id=p_business_id and kind in ('customer','both');$old$;
 v_new_customer text := $new$where id=p_customer_id and business_id=p_business_id and kind in ('customer','both') and is_active;$new$;
 v_old_product text := $old$where id=(v_item->>'product_id')::uuid and business_id=p_business_id
    for update;$old$;
 v_new_product text := $new$where id=(v_item->>'product_id')::uuid and business_id=p_business_id and is_active
    for update;$new$;
begin
 select pg_get_functiondef('public.post_sale(uuid,text,uuid,date,jsonb,numeric,numeric,text)'::regprocedure) into v_def;
 if position(v_old_lock in v_def)>0 then v_def:=replace(v_def,v_old_lock,v_new_lock); end if;
 if position(v_old_customer in v_def)>0 then v_def:=replace(v_def,v_old_customer,v_new_customer); end if;
 if position(v_old_product in v_def)>0 then v_def:=replace(v_def,v_old_product,v_new_product); end if;
 if position('and p.is_active' in v_def)=0
   or position('and is_active;' in v_def)=0
   or position('business_id=p_business_id and is_active' in v_def)=0 then
  raise exception 'Could not safely enforce active customer and product checks in post_sale';
 end if;
 execute v_def;
end $$;