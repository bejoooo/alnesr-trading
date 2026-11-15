-- 019: Restrict direct writes to master-data columns and route staff changes through an owner RPC.
-- Accounting-sensitive fields must only be changed by their dedicated database operations.

-- Businesses: the browser may create a business and edit only its public profile fields.
revoke insert, update on table public.businesses from public, anon, authenticated;
grant insert (name, phone, address, created_by) on table public.businesses to authenticated;
grant update (name, phone, address) on table public.businesses to authenticated;

-- Products: protect tenant identity, stock status, timestamps and average cost.
-- average_cost is additionally guarded by products_guard_average_cost and inventory RPCs.
revoke insert, update on table public.products from public, anon, authenticated;
grant insert (id, business_id, code, name, category, unit, wholesale_price, retail_price,
              minimum_stock, warranty, warranty_provider, specs, image_path)
on table public.products to authenticated;
grant update (code, name, category, unit, wholesale_price, retail_price,
              minimum_stock, warranty, warranty_provider, specs, image_path)
on table public.products to authenticated;

-- Parties: opening balances and their side are only mutable through set_party_opening_balance.
revoke insert, update on table public.parties from public, anon, authenticated;
grant insert (business_id, kind, name, company, phone, address, customer_type, notes)
on table public.parties to authenticated;
grant update (name, company, phone, address, customer_type, notes)
on table public.parties to authenticated;

-- Membership identity and membership lifecycle are managed only by SECURITY DEFINER RPCs.
-- The UI no longer writes business_members directly.
revoke insert, update, delete on table public.business_members from public, anon, authenticated;

create or replace function public.update_business_member(
  p_business_id uuid,
  p_user_id uuid,
  p_role text,
  p_active boolean,
  p_permissions jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  target_role text;
begin
  if auth.uid() is null or not exists (
    select 1 from public.business_members m
    where m.business_id = p_business_id
      and m.user_id = auth.uid()
      and m.role = 'owner'
      and m.active = true
  ) then
    raise exception 'OWNER_REQUIRED';
  end if;

  if p_role not in ('manager', 'cashier', 'viewer') or p_active is null
     or jsonb_typeof(p_permissions) <> 'object' then
    raise exception 'INVALID_MEMBER_INPUT';
  end if;

  if exists (
    select 1
    from jsonb_each(p_permissions) e
    where e.key <> all (array[
      'products.view','products.create','products.edit',
      'parties.view','parties.create','parties.edit',
      'purchases.view','purchases.create','purchases.edit',
      'sales.view','sales.create','sales.edit',
      'payments.view','payments.create','payments.record',
      'inventory.view','inventory.create',
      'expenses.view','expenses.create','expenses.edit',
      'cash.view','cash.create','cash.deposit','cash.withdraw',
      'settings.view','audit.view'
    ]::text[])
    or jsonb_typeof(e.value) <> 'boolean'
  ) then
    raise exception 'INVALID_MEMBER_PERMISSIONS';
  end if;

  select m.role into target_role
  from public.business_members m
  where m.business_id = p_business_id and m.user_id = p_user_id
  for update;

  if not found then
    raise exception 'MEMBER_NOT_FOUND';
  end if;
  if target_role in ('owner', 'admin') then
    raise exception 'PROTECTED_MEMBER';
  end if;

  update public.business_members
  set role = p_role, active = p_active, permissions = p_permissions
  where business_id = p_business_id and user_id = p_user_id;
end;
$function$;

revoke all on function public.update_business_member(uuid, uuid, text, boolean, jsonb) from public, anon;
grant execute on function public.update_business_member(uuid, uuid, text, boolean, jsonb) to authenticated;

-- Assertions: fail the migration if a protected field is still directly writable.
do $assert$
begin
  if has_column_privilege('authenticated','public.products','average_cost','INSERT')
     or has_column_privilege('authenticated','public.products','average_cost','UPDATE')
     or has_column_privilege('authenticated','public.products','business_id','UPDATE')
     or has_column_privilege('authenticated','public.products','is_active','UPDATE') then
    raise exception 'Migration 019 assertion failed: protected product columns remain writable';
  end if;

  if has_column_privilege('authenticated','public.parties','opening_balance','INSERT')
     or has_column_privilege('authenticated','public.parties','opening_balance','UPDATE')
     or has_column_privilege('authenticated','public.parties','opening_balance_side','INSERT')
     or has_column_privilege('authenticated','public.parties','opening_balance_side','UPDATE')
     or has_column_privilege('authenticated','public.parties','business_id','UPDATE')
     or has_column_privilege('authenticated','public.parties','kind','UPDATE') then
    raise exception 'Migration 019 assertion failed: protected party columns remain writable';
  end if;

  if has_column_privilege('authenticated','public.businesses','created_by','UPDATE')
     or has_column_privilege('authenticated','public.businesses','currency','UPDATE') then
    raise exception 'Migration 019 assertion failed: protected business columns remain writable';
  end if;

  if has_table_privilege('authenticated','public.business_members','INSERT')
     or has_table_privilege('authenticated','public.business_members','UPDATE')
     or has_table_privilege('authenticated','public.business_members','DELETE') then
    raise exception 'Migration 019 assertion failed: direct membership writes remain available';
  end if;

  if not has_column_privilege('authenticated','public.products','name','UPDATE')
     or not has_column_privilege('authenticated','public.parties','name','INSERT')
     or not has_column_privilege('authenticated','public.businesses','name','UPDATE') then
    raise exception 'Migration 019 assertion failed: required browser write privileges are missing';
  end if;
end;
$assert$;
