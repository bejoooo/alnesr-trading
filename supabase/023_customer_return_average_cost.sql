-- 023: Recalculate weighted average cost when good customer returns re-enter stock.
create or replace function public.apply_customer_return_average_cost()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  old_average numeric(14,4);
  total_quantity numeric(14,3);
  old_quantity numeric(14,3);
  new_average numeric(14,2);
begin
  if new.movement_type <> 'customer_return_good' then
    return new;
  end if;
  if new.quantity_delta <= 0 or new.unit_cost is null or new.unit_cost < 0 then
    raise exception 'Invalid good customer return stock movement cost or quantity';
  end if;

  select p.average_cost into old_average
  from public.products p
  where p.id = new.product_id and p.business_id = new.business_id
  for update;
  if not found then
    raise exception 'Product for customer return movement was not found';
  end if;

  select coalesce(sum(sm.quantity_delta),0)
  into total_quantity
  from public.stock_movements sm
  where sm.business_id = new.business_id and sm.product_id = new.product_id;

  old_quantity := total_quantity - new.quantity_delta;
  if old_quantity < 0 or total_quantity <= 0 then
    raise exception 'Invalid stock balance while applying customer return';
  end if;

  new_average := round(
    ((old_quantity * old_average) + (new.quantity_delta * new.unit_cost)) / total_quantity,
    2
  );

  update public.products
  set average_cost = new_average, updated_at = now()
  where id = new.product_id and business_id = new.business_id;

  return new;
end;
$function$;

drop trigger if exists stock_movements_customer_return_average_cost on public.stock_movements;
create trigger stock_movements_customer_return_average_cost
after insert on public.stock_movements
for each row
when (new.movement_type = 'customer_return_good')
execute function public.apply_customer_return_average_cost();