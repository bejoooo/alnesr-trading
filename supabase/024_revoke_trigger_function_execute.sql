-- 024: Trigger functions are internal implementation details, not RPC endpoints.
revoke all on function public.guard_party_opening_balance_side() from public, anon, authenticated;
revoke all on function public.lock_invoice_party_for_opening_balance() from public, anon, authenticated;
revoke all on function public.apply_customer_return_average_cost() from public, anon, authenticated;

do $assert$
begin
  if has_function_privilege('anon','public.guard_party_opening_balance_side()','EXECUTE')
     or has_function_privilege('authenticated','public.guard_party_opening_balance_side()','EXECUTE')
     or has_function_privilege('anon','public.lock_invoice_party_for_opening_balance()','EXECUTE')
     or has_function_privilege('authenticated','public.lock_invoice_party_for_opening_balance()','EXECUTE')
     or has_function_privilege('anon','public.apply_customer_return_average_cost()','EXECUTE')
     or has_function_privilege('authenticated','public.apply_customer_return_average_cost()','EXECUTE') then
    raise exception 'Migration 024 assertion failed: trigger functions remain executable by API roles';
  end if;
end;
$assert$;