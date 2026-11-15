-- Al Nesr Trading — enforce owner-only staff membership management
-- The staff directory and member onboarding are owner-only features.
-- Do not rely on the UI: enforce the same rule at the RLS layer.

drop policy if exists members_admin_insert on public.business_members;
drop policy if exists members_admin_update on public.business_members;
drop policy if exists members_admin_delete on public.business_members;
drop policy if exists members_owner_insert on public.business_members;
drop policy if exists members_owner_update on public.business_members;
drop policy if exists members_owner_delete on public.business_members;

create policy members_owner_insert
on public.business_members
for insert
to authenticated
with check (public.has_business_role(business_id, array['owner']));

create policy members_owner_update
on public.business_members
for update
to authenticated
using (public.has_business_role(business_id, array['owner']))
with check (public.has_business_role(business_id, array['owner']));

create policy members_owner_delete
on public.business_members
for delete
to authenticated
using (public.has_business_role(business_id, array['owner']));

do $$
declare
  policy_count integer;
begin
  select count(*) into policy_count
  from pg_policies
  where schemaname='public'
    and tablename='business_members'
    and cmd in ('INSERT','UPDATE','DELETE')
    and (
      coalesce(qual,'') ilike '%admin%'
      or coalesce(with_check,'') ilike '%admin%'
      or coalesce(qual,'') not ilike '%owner%'
      or coalesce(with_check,'') not ilike '%owner%'
    );

  if policy_count <> 0 then
    raise exception 'Unexpected non-owner membership DML policy remains';
  end if;
end;
$$;
