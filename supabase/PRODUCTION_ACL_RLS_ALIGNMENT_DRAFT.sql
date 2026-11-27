-- DRAFT ONLY — align the two direct-access differences confirmed by Test/Production audit.
-- Apply only after PRODUCTION_MISSING_COLUMNS_DRAFT.sql.
-- This does not grant table-wide UPDATE and does not change other RLS policies.

begin;

-- Preview directly updates only the tagline among the business profile fields added here.
-- Keep SELECT/UPDATE column-scoped; the existing businesses RLS policy still limits rows.
grant select (tagline), update (tagline) on public.businesses to authenticated;

-- Match the tested payments visibility rule:
-- invoice payments require payments.view plus the relevant sales/purchases view permission;
-- standalone customer/supplier payments also require the matching account permission;
-- untyped standalone payments remain owner/admin-only.
alter policy payments_read on public.payments
using (
  public.has_business_permission(business_id,'payments.view')
  and (
    exists (
      select 1 from public.sales_invoices si
      where si.id=payments.invoice_id
        and si.business_id=payments.business_id
        and public.has_business_permission(payments.business_id,'sales.view')
    )
    or exists (
      select 1 from public.purchase_invoices pi
      where pi.id=payments.invoice_id
        and pi.business_id=payments.business_id
        and public.has_business_permission(payments.business_id,'purchases.view')
    )
    or (
      invoice_id is null
      and party_account_type='customer'
      and public.has_business_permission(business_id,'sales.view')
    )
    or (
      invoice_id is null
      and party_account_type='supplier'
      and public.has_business_permission(business_id,'purchases.view')
    )
    or (
      invoice_id is null
      and party_account_type is null
      and public.has_business_role(business_id,array['owner','admin']::text[])
    )
  )
);

commit;
