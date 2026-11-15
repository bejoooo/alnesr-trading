-- 020: Remove destructive and schema-changing table privileges from API roles.
-- The application has no direct row-deletion workflow; accounting changes use RPCs.
do $migration$
declare
  t record;
begin
  for t in
    select schemaname, tablename
    from pg_tables
    where schemaname = 'public'
  loop
    execute format(
      'revoke delete, truncate, references, trigger on table %I.%I from public, anon, authenticated',
      t.schemaname, t.tablename
    );
  end loop;
end;
$migration$;

do $assert$
begin
  if exists (
    select 1
    from information_schema.role_table_grants
    where table_schema='public'
      and grantee in ('anon','authenticated')
      and privilege_type in ('DELETE','TRUNCATE','REFERENCES','TRIGGER')
  ) then
    raise exception 'Migration 020 assertion failed: destructive table privileges remain on public tables';
  end if;
end;
$assert$;