-- Al Nesr Trading — access-control hardening migration
-- Apply AFTER schema.sql. This migration replaces the broad member-write policies
-- with role/permission-aware policies. Review and test on a disposable project first.

create or replace function public.has_business_permission(bid uuid, permission_key text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.business_members m
    where m.business_id = bid
      and m.user_id = auth.uid()
      and m.active = true
      and (
        m.role in ('owner', 'admin')
        or case
          when m.permissions ? permission_key
            then m.permissions -> permission_key = 'true'::jsonb
          else
            case m.role
              when 'manager' then permission_key not in ('members.manage', 'settings.edit', 'audit.view')
              when 'cashier' then permission_key in (
                'products.view', 'parties.view', 'parties.create',
                'sales.view', 'sales.create', 'sales.edit',
                'payments.view', 'payments.create', 'payments.record',
                'inventory.view', 'cash.view', 'cash.create', 'cash.deposit', 'cash.withdraw'
              )
              when 'viewer' then permission_key in (
                'products.view', 'parties.view', 'purchases.view',
                'sales.view', 'payments.view', 'inventory.view',
                'expenses.view', 'cash.view', 'settings.view', 'audit.view'
              )
              else false
            end
        end
      )
  );
$$;

-- Prevent an admin from promoting someone to owner/admin or changing an owner's account.
create or replace function public.guard_business_member_changes()
returns trigger
language plpgsql
security invoker
set search_path = public
as $$
declare
  actor_is_owner boolean;
begin
  if auth.uid() is null then
    raise exception 'Authenticated user required';
  end if;

  actor_is_owner := public.has_business_role(
    coalesce(new.business_id, old.business_id),
    array['owner']
  );

  -- Allow the schema's creator trigger to create the very first owner membership.
  if tg_op = 'INSERT' and new.role = 'owner' and new.user_id = auth.uid()
     and exists (
       select 1 from public.businesses b
       where b.id = new.business_id and b.created_by = auth.uid()
     )
     and not exists (
       select 1 from public.business_members m
       where m.business_id = new.business_id
     ) then
    actor_is_owner := true;
  end if;

  if tg_op = 'UPDATE' then
    if new.business_id <> old.business_id or new.user_id <> old.user_id then
      raise exception 'Membership identity cannot be changed';
    end if;
    if (old.role = 'owner' or old.role = 'admin' or new.role = 'owner' or new.role = 'admin')
       and not actor_is_owner then
      raise exception 'Only the business owner can manage owner/admin memberships';
    end if;
  elsif tg_op = 'INSERT' then
    if (new.role = 'owner' or new.role = 'admin') and not actor_is_owner then
      raise exception 'Only the business owner can assign owner/admin roles';
    end if;
  elsif tg_op = 'DELETE' then
    if (old.role = 'owner' or old.role = 'admin') and not actor_is_owner then
      raise exception 'Only the business owner can remove owner/admin memberships';
    end if;
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists business_members_guard on public.business_members;
create trigger business_members_guard
before insert or update or delete on public.business_members
for each row execute function public.guard_business_member_changes();

-- Replace the original "all members can do everything" policy.
do $$
declare
  item record;
begin
  for item in
    select * from (values
      ('products', 'products'),
      ('parties', 'parties'),
      ('purchase_invoices', 'purchases'),
      ('purchase_items', 'purchases'),
      ('sales_invoices', 'sales'),
      ('sales_items', 'sales'),
      ('payments', 'payments'),
      ('stock_movements', 'inventory'),
      ('sales_returns', 'sales'),
      ('sales_return_items', 'sales'),
      ('expenses', 'expenses'),
      ('cash_transactions', 'cash'),
      ('business_settings', 'settings')
    ) as policy_map(table_name, permission_prefix)
  loop
    execute format('drop policy if exists %I on public.%I', item.table_name || '_member_access', item.table_name);
    execute format('drop policy if exists %I on public.%I', item.table_name || '_read', item.table_name);
    execute format('drop policy if exists %I on public.%I', item.table_name || '_insert', item.table_name);
    execute format('drop policy if exists %I on public.%I', item.table_name || '_update', item.table_name);
    execute format('drop policy if exists %I on public.%I', item.table_name || '_delete', item.table_name);

    execute format(
      'create policy %I on public.%I for select using (public.has_business_permission(business_id, %L))',
      item.table_name || '_read', item.table_name, item.permission_prefix || '.view'
    );
    execute format(
      'create policy %I on public.%I for insert with check (public.has_business_permission(business_id, %L))',
      item.table_name || '_insert', item.table_name, item.permission_prefix || '.create'
    );
    execute format(
      'create policy %I on public.%I for update using (public.has_business_permission(business_id, %L)) with check (public.has_business_permission(business_id, %L))',
      item.table_name || '_update', item.table_name,
      item.permission_prefix || '.edit', item.permission_prefix || '.edit'
    );
    execute format(
      'create policy %I on public.%I for delete using (public.has_business_permission(business_id, %L))',
      item.table_name || '_delete', item.table_name, item.permission_prefix || '.delete'
    );
  end loop;
end $$;

-- Audit entries are readable by owner/admin and are not directly editable by staff.
drop policy if exists audit_log_member_access on public.audit_log;
drop policy if exists audit_log_read on public.audit_log;
create policy audit_log_read on public.audit_log
for select using (public.has_business_permission(business_id, 'audit.view'));

-- Membership reads remain available to members; writes remain owner/admin-only,
-- with the trigger above preventing admin privilege escalation.
