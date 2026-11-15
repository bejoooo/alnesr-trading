-- Al Nesr Trading — membership policy and RLS performance cleanup
-- Apply after 014_membership_privacy.sql on the TEST project first.
-- Members can read their own membership row. Owner/admin DML remains governed
-- by the role helper and the membership guard trigger. SELECT is deliberately
-- not bundled into an ALL policy, avoiding a second permissive SELECT policy.

drop policy if exists members_admin_manage on public.business_members;
drop policy if exists members_admin_insert on public.business_members;
drop policy if exists members_admin_update on public.business_members;
drop policy if exists members_admin_delete on public.business_members;

create policy members_admin_insert
on public.business_members
for insert
to authenticated
with check (public.has_business_role(business_id, array['owner','admin']));

create policy members_admin_update
on public.business_members
for update
to authenticated
using (public.has_business_role(business_id, array['owner','admin']))
with check (public.has_business_role(business_id, array['owner','admin']));

create policy members_admin_delete
on public.business_members
for delete
to authenticated
using (public.has_business_role(business_id, array['owner','admin']));

-- Evaluate auth.uid() once per statement rather than once per candidate row.
drop policy if exists members_read on public.business_members;
create policy members_read
on public.business_members
for select
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists businesses_creator_insert on public.businesses;
create policy businesses_creator_insert
on public.businesses
for insert
to authenticated
with check (created_by = (select auth.uid()));

do $$
declare
  self_read_qual text;
begin
  select qual into self_read_qual
  from pg_policies
  where schemaname='public' and tablename='business_members'
    and policyname='members_read' and cmd='SELECT';

  if self_read_qual is null
     or position('user_id' in self_read_qual)=0
     or position('auth.uid' in self_read_qual)=0 then
    raise exception 'Membership self-read policy is missing or malformed';
  end if;

  if exists (
    select 1 from pg_policies
    where schemaname='public' and tablename='business_members'
      and policyname='members_admin_manage'
  ) then
    raise exception 'Legacy permissive membership policy still exists';
  end if;
end;
$$;
