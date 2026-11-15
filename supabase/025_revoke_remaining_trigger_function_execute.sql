-- 025: Revoke direct API execution from remaining trigger-only functions.
revoke all on function public.guard_business_member_changes() from public, anon, authenticated;
revoke all on function public.guard_product_average_cost() from public, anon, authenticated;

do $assert$
begin
  if has_function_privilege('anon','public.guard_business_member_changes()','EXECUTE')
     or has_function_privilege('authenticated','public.guard_business_member_changes()','EXECUTE')
     or has_function_privilege('anon','public.guard_product_average_cost()','EXECUTE')
     or has_function_privilege('authenticated','public.guard_product_average_cost()','EXECUTE') then
    raise exception 'Migration 025 assertion failed: trigger-only functions remain directly executable';
  end if;
end;
$assert$;