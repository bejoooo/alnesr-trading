-- 029: New public tables are read-only to API roles unless a migration explicitly grants writes.
alter default privileges for role postgres in schema public
  revoke insert, update on tables from anon, authenticated;

do $assert$
begin
  if exists (
    select 1
    from pg_default_acl d
    join pg_namespace n on n.oid=d.defaclnamespace
    cross join lateral aclexplode(d.defaclacl) x
    where n.nspname='public'
      and d.defaclrole=(select oid from pg_roles where rolname='postgres')
      and d.defaclobjtype='r'
      and x.grantee in (select oid from pg_roles where rolname in ('anon','authenticated'))
      and x.privilege_type in ('INSERT','UPDATE')
  ) then
    raise exception 'Migration 029 assertion failed: default direct writes remain for API roles';
  end if;
end;
$assert$;