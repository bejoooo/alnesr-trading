-- 027: Revoke PostgreSQL's global default PUBLIC execute grant for future functions.
-- Per-schema REVOKE cannot remove a global default grant, so this must be global for postgres.
alter default privileges for role postgres
  revoke execute on functions from public;

do $assert$
begin
  if exists (
    select 1
    from pg_default_acl d
    cross join lateral aclexplode(d.defaclacl) x
    where d.defaclrole=(select oid from pg_roles where rolname='postgres')
      and d.defaclobjtype='f'
      and x.grantee=0
      and x.privilege_type='EXECUTE'
  ) then
    raise exception 'Migration 027 assertion failed: global PUBLIC function execute default remains';
  end if;
end;
$assert$;