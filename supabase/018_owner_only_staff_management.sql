-- Al Nesr Trading — enforce owner-only staff membership management
-- Staff membership DML is restricted to active business owners at the RLS layer.

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
begin
  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='business_members'
      and cmd='INSERT'
      and coalesce(with_check,'') not ilike '%has_business_role%'
  ) then raise exception 'Owner-only INSERT policy verification failed'; end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='business_members'
      and cmd='UPDATE'
      and (coalesce(qual,'') not ilike '%has_business_role%'
        or coalesce(with_check,'') not ilike '%has_business_role%')
  ) then raise exception 'Owner-only UPDATE policy verification failed'; end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='business_members'
      and cmd='DELETE'
      and coalesce(qual,'') not ilike '%has_business_role%'
  ) then raise exception 'Owner-only DELETE policy verification failed'; end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='business_members'
      and cmd in ('INSERT','UPDATE','DELETE')
      and (coalesce(qual,'') ilike '%admin%'
        or coalesce(with_check,'') ilike '%admin%')
  ) then raise exception 'Admin role still appears in membership DML policy'; end if;
end;
$$;
