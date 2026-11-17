-- Cashiers can post sales collections but manual cash deposits/withdrawals require explicit owner permission.
CREATE OR REPLACE FUNCTION public.has_business_permission(bid uuid, permission_key text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
              when 'manager' then permission_key in (
                'products.view', 'products.create', 'products.edit',
                'parties.view', 'parties.create', 'parties.edit',
                'purchases.view', 'purchases.create', 'purchases.edit',
                'sales.view', 'sales.create', 'sales.edit',
                'payments.view', 'payments.create', 'payments.record',
                'inventory.view', 'inventory.create',
                'expenses.view', 'expenses.create', 'expenses.edit',
                'cash.view', 'cash.create', 'cash.deposit', 'cash.withdraw',
                'settings.view'
              )
              when 'cashier' then permission_key in (
                'products.view', 'parties.view', 'parties.create',
                'sales.view', 'sales.create', 'sales.edit',
                'payments.view', 'payments.create', 'payments.record',
                'inventory.view', 'cash.view', 'cash.create'
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
$function$
