-- 026: Make safe API privileges the default for future public objects.
-- Existing objects are covered as well as objects created by postgres/supabase_admin later.
do $migration$
declare t record;
begin
  for t in
    select n.nspname as schemaname, c.relname as objectname
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p','v','m','f')
  loop
    execute format(
      'revoke delete, truncate, references, trigger, maintain on table %I.%I from anon, authenticated',
      t.schemaname, t.objectname
    );
  end loop;
end;
$migration$;

alter default privileges for role postgres in schema public
  revoke delete, truncate, references, trigger, maintain on tables from anon, authenticated;
alter default privileges for role supabase_admin in schema public
  revoke delete, truncate, references, trigger, maintain on tables from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;
alter default privileges for role supabase_admin in schema public
  revoke execute on functions from public, anon, authenticated;

do $assert$
begin
  if exists (
    select 1 from information_schema.role_table_grants
    where table_schema='public'
      and grantee in ('anon','authenticated')
      and privilege_type in ('DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  ) then
    raise exception 'Migration 026 assertion failed: unnecessary table privileges remain';
  end if;

  if exists (
    select 1
    from pg_default_acl d
    join pg_namespace n on n.oid=d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) x
    where n.nspname='public'
      and d.defaclobjtype='r'
      and x.grantee in (select oid from pg_roles where rolname in ('anon','authenticated'))
      and x.privilege_type in ('DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
  ) then
    raise exception 'Migration 026 assertion failed: unsafe table defaults remain';
  end if;

  if exists (
    select 1
    from pg_default_acl d
    join pg_namespace n on n.oid=d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) x
    where n.nspname='public'
      and d.defaclobjtype='f'
      and (x.grantee=0 or x.grantee in (select oid from pg_roles where rolname in ('anon','authenticated')))
      and x.privilege_type='EXECUTE'
  ) then
    raise exception 'Migration 026 assertion failed: PUBLIC/API function execute defaults remain';
  end if;
end;
$assert$;