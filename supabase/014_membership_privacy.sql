-- Al Nesr Trading — membership privacy hardening
-- Apply after 013_staff_management.sql on the TEST project first.
-- Staff need to read only their own membership for workspace bootstrap.
-- Owners/admins retain access through members_admin_manage; the owner-only
-- list_business_members RPC remains the supported staff-directory endpoint.

drop policy if exists members_read on public.business_members;
create policy members_read
on public.business_members
for select
to authenticated
using (user_id = auth.uid());

-- Structural check: the self-read policy must not grant cross-member access.
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='public'
      and tablename='business_members'
      and policyname='members_read'
      and cmd='SELECT'
      and qual like '%user_id = auth.uid()%'
  ) then
    raise exception 'Membership self-read policy was not installed';
  end if;
end;
$$;
