-- 020: Remove destructive and schema-changing privileges from API roles.
-- Apply to tables and views, including security-invoker reporting views.
do $migration$
declare t record;
begin
  for t in
    select n.nspname as schemaname, c.relname as objectname
    from pg_class c
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('r','p','v','m','f')
  loop
    execute format(
      'revoke delete, truncate, references, trigger on table %I.%I from anon, authenticated',
      t.schemaname, t.objectname
    );
  end loop;
end;
$migration$;

do $assert$
begin
  if exists (
    select 1 from information_schema.role_table_grants
    where table_schema='public'
      and grantee in ('anon','authenticated')
      and privilege_type in ('DELETE','TRUNCATE','REFERENCES','TRIGGER')
  ) then
    raise exception 'Migration 020 assertion failed: destructive API privileges remain on public relations';
  end if;
end;
$assert$;