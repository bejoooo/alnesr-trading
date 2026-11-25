-- Read-only verifier for the isolated high-risk reset RPC.
-- It inspects function metadata/body only and never calls reset_business_data.

do $verify$
declare
  v_oid oid;
  v_definition text;
begin
  v_oid:=to_regprocedure('public.reset_business_data(uuid)');
  if v_oid is null then
    raise exception 'reset_business_data(uuid) is missing';
  end if;

  select pg_get_functiondef(v_oid) into v_definition;

  if not exists (
    select 1 from pg_proc p
    where p.oid=v_oid and p.prosecdef
      and coalesce(p.proconfig,'{}'::text[]) @> array['search_path=""']
  ) then
    raise exception 'Reset function must be SECURITY DEFINER with empty search_path';
  end if;

  if v_definition not ilike '%auth.uid()%'
     or v_definition not ilike '%role=''owner''%'
     or v_definition not ilike '%active=true%'
     or v_definition not ilike '%pg_advisory_xact_lock%' then
    raise exception 'Reset function is missing owner/auth/active/serialization guards';
  end if;

  if v_definition ilike '%delete from public.businesses%'
     or v_definition ilike '%delete from public.business_members%' then
    raise exception 'Reset function must preserve business and owner membership';
  end if;

  if not has_function_privilege('authenticated','public.reset_business_data(uuid)','EXECUTE')
     or not has_function_privilege('service_role','public.reset_business_data(uuid)','EXECUTE') then
    raise exception 'Reset function missing expected execution grants';
  end if;

  if has_function_privilege('anon','public.reset_business_data(uuid)','EXECUTE') then
    raise exception 'anon unexpectedly has EXECUTE on reset function';
  end if;

  if exists (
    select 1 from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
    where p.oid=v_oid and a.grantee=0 and a.privilege_type='EXECUTE'
  ) then
    raise exception 'PUBLIC unexpectedly has EXECUTE on reset function';
  end if;

  raise notice 'PASS: reset RPC is owner-gated, serialized, preserves business/membership, and has restricted ACL';
end
$verify$;
