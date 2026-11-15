-- 031: Restrict internal SECURITY DEFINER helpers and trigger functions.
-- RLS helpers remain executable by authenticated because policies call them.
revoke all on function public.add_business_creator_as_owner() from public, anon, authenticated;
revoke all on function public.guard_invoice_reference_business() from public, anon, authenticated;
revoke all on function public.rls_auto_enable() from public, anon, authenticated;

revoke all on function public.has_business_permission(uuid, text) from public, anon;
grant execute on function public.has_business_permission(uuid, text) to authenticated;
revoke all on function public.has_business_role(uuid, text[]) from public, anon;
grant execute on function public.has_business_role(uuid, text[]) to authenticated;
revoke all on function public.is_business_member(uuid) from public, anon;
grant execute on function public.is_business_member(uuid) to authenticated;

revoke all on function public.restore_business_backup(uuid, jsonb) from public, anon;
grant execute on function public.restore_business_backup(uuid, jsonb) to authenticated;

do $assert$
begin
 if has_function_privilege('anon','public.add_business_creator_as_owner()','EXECUTE')
    or has_function_privilege('authenticated','public.add_business_creator_as_owner()','EXECUTE')
    or has_function_privilege('anon','public.guard_invoice_reference_business()','EXECUTE')
    or has_function_privilege('authenticated','public.guard_invoice_reference_business()','EXECUTE')
    or has_function_privilege('anon','public.rls_auto_enable()','EXECUTE')
    or has_function_privilege('authenticated','public.rls_auto_enable()','EXECUTE')
    or has_function_privilege('anon','public.restore_business_backup(uuid,jsonb)','EXECUTE')
    or has_function_privilege('anon','public.has_business_permission(uuid,text)','EXECUTE')
    or has_function_privilege('anon','public.has_business_role(uuid,text[])','EXECUTE')
    or has_function_privilege('anon','public.is_business_member(uuid)','EXECUTE') then
   raise exception 'Migration 031 assertion failed: an internal function remains publicly executable';
 end if;
 if not has_function_privilege('authenticated','public.restore_business_backup(uuid,jsonb)','EXECUTE')
    or not has_function_privilege('authenticated','public.has_business_permission(uuid,text)','EXECUTE')
    or not has_function_privilege('authenticated','public.has_business_role(uuid,text[])','EXECUTE')
    or not has_function_privilege('authenticated','public.is_business_member(uuid)','EXECUTE') then
   raise exception 'Migration 031 assertion failed: required authenticated function execution is missing';
 end if;
end;
$assert$;
