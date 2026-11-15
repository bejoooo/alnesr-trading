-- Al Nesr Trading — owner-only staff directory and membership onboarding
-- Apply on the TEST project only after review.
create or replace function public.list_business_members(p_business_id uuid)
returns table(user_id uuid,email text,role text,permissions jsonb,active boolean,created_at timestamptz)
language plpgsql security definer set search_path = ''
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.business_members m where m.business_id=p_business_id and m.user_id=auth.uid() and m.role='owner' and m.active=true) then
  raise exception 'OWNER_REQUIRED';
 end if;
 return query select m.user_id,u.email::text,m.role,m.permissions,m.active,m.created_at
 from public.business_members m join auth.users u on u.id=m.user_id
 where m.business_id=p_business_id
 order by case when m.role='owner' then 0 else 1 end,lower(coalesce(u.email,''));
end;
$$;
create or replace function public.add_business_member_by_email(p_business_id uuid,p_email text,p_role text)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare target_user_id uuid; normalized_email text := lower(btrim(coalesce(p_email,'')));
begin
 if auth.uid() is null or not exists(select 1 from public.business_members m where m.business_id=p_business_id and m.user_id=auth.uid() and m.role='owner' and m.active=true) then
  raise exception 'OWNER_REQUIRED';
 end if;
 if normalized_email='' or p_role not in ('manager','cashier','viewer') then raise exception 'INVALID_MEMBER_INPUT'; end if;
 select u.id into target_user_id from auth.users u where lower(u.email)=normalized_email and u.email_confirmed_at is not null limit 1;
 if target_user_id is null then raise exception 'USER_NOT_FOUND_OR_UNCONFIRMED'; end if;
 insert into public.business_members(business_id,user_id,role,permissions,active) values(p_business_id,target_user_id,p_role,'{}'::jsonb,true)
 on conflict(business_id,user_id) do nothing;
 if not found then raise exception 'MEMBER_ALREADY_EXISTS'; end if;
 return target_user_id;
end;
$$;
revoke all on function public.list_business_members(uuid) from public,anon;
grant execute on function public.list_business_members(uuid) to authenticated;
revoke all on function public.add_business_member_by_email(uuid,text,text) from public,anon;
grant execute on function public.add_business_member_by_email(uuid,text,text) to authenticated;
