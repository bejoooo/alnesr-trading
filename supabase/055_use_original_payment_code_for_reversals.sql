-- Keep every payment reversal tied to the exact visible reference of its original payment.
-- This is a reporting-only change: payment rows, balances, cash movements and reversal links are untouched.

create or replace view public.party_account_statement
with (security_invoker = true)
as
select
    p.business_id,
    p.id as party_id,
    p.name as party_name,
    'opening_balance'::text as entry_type,
    null::uuid as entry_id,
    null::text as reference_no,
    p.created_at::date as entry_date,
    case when p.opening_balance_side = 'receivable'::text then p.opening_balance else 0::numeric end as debit,
    case when p.opening_balance_side = 'payable'::text then p.opening_balance else 0::numeric end as credit,
    'رصيد افتتاحي'::text as description,
    p.created_at as entry_timestamp
from public.parties p
where p.opening_balance <> 0::numeric

union all

select
    i.business_id,
    i.customer_id as party_id,
    p.name as party_name,
    'sale_invoice'::text as entry_type,
    i.id as entry_id,
    i.invoice_no as reference_no,
    i.invoice_date as entry_date,
    i.total::numeric as debit,
    0::numeric as credit,
    'فاتورة مبيعات'::text as description,
    i.created_at as entry_timestamp
from public.sales_invoices i
join public.parties p on p.id = i.customer_id and p.business_id = i.business_id
where i.customer_id is not null and i.status <> 'void'::text

union all

select
    i.business_id,
    i.supplier_id as party_id,
    p.name as party_name,
    'purchase_invoice'::text as entry_type,
    i.id as entry_id,
    i.invoice_no as reference_no,
    i.invoice_date as entry_date,
    0::numeric as debit,
    i.total::numeric as credit,
    'فاتورة مشتريات'::text as description,
    i.created_at as entry_timestamp
from public.purchase_invoices i
join public.parties p on p.id = i.supplier_id and p.business_id = i.business_id
where i.supplier_id is not null and i.status <> 'void'::text

union all

select
    x.business_id,
    x.party_id,
    p.name as party_name,
    case
        when x.reversal_of_payment_id is not null then 'payment'::text
        when x.invoice_id is null
          and x.sales_return_id is null
          and x.party_account_type = any (array['customer'::text, 'supplier'::text])
        then case
            when exists (
                select 1 from public.payments rv
                where rv.reversal_of_payment_id = x.id
            ) then 'reversed_standalone_payment'::text
            else 'standalone_payment'::text
        end
        else 'payment'::text
    end as entry_type,
    x.id as entry_id,
    case
        when x.reversal_of_payment_id is not null
        then coalesce(
            nullif(concat_ws(' · ', original.payment_code, original.reference), ''),
            'بدون كود'
        )
        else concat_ws(' · ', x.payment_code, x.reference)
    end as reference_no,
    x.payment_date as entry_date,
    case when x.direction = 'out'::text then x.amount else 0::numeric end as debit,
    case when x.direction = 'in'::text then x.amount else 0::numeric end as credit,
    case
        when x.reversal_of_payment_id is not null then 'قيد عكسي لدفعة'::text
        when x.invoice_id is null and x.sales_return_id is null
        then case
            when x.party_account_type = 'customer'::text then 'تحصيل مستقل من عميل'::text
            else 'سداد مستقل لمورد'::text
        end
        else coalesce(x.notes, 'دفعة'::text)
    end as description,
    coalesce(x.posted_at, x.created_at) as entry_timestamp
from public.payments x
join public.parties p on p.id = x.party_id and p.business_id = x.business_id
left join public.payments original
    on original.id = x.reversal_of_payment_id
   and original.business_id = x.business_id
where x.party_id is not null
  and (
      (
          x.sales_return_id is not null
          and exists (
              select 1 from public.sales_returns r
              where r.id = x.sales_return_id
                and r.business_id = x.business_id
                and r.status <> 'void'::text
          )
      )
      or (
          x.sales_return_id is null
          and x.invoice_id is not null
          and (
              exists (
                  select 1 from public.sales_invoices si
                  where si.id = x.invoice_id
                    and si.business_id = x.business_id
                    and si.status <> 'void'::text
              )
              or exists (
                  select 1 from public.purchase_invoices pi
                  where pi.id = x.invoice_id
                    and pi.business_id = x.business_id
                    and pi.status <> 'void'::text
              )
          )
      )
      or (
          x.sales_return_id is null
          and x.invoice_id is null
          and x.party_account_type = any (array['customer'::text, 'supplier'::text])
      )
  )

union all

select
    r.business_id,
    r.customer_id as party_id,
    p.name as party_name,
    'sales_return'::text as entry_type,
    r.id as entry_id,
    r.return_no as reference_no,
    r.return_date as entry_date,
    0::numeric as debit,
    r.refund_total::numeric as credit,
    'مرتجع مبيعات'::text as description,
    coalesce(r.posted_at, r.created_at) as entry_timestamp
from public.sales_returns r
join public.parties p on p.id = r.customer_id and p.business_id = r.business_id
where r.customer_id is not null and r.status <> 'void'::text

union all

select
    r.business_id,
    r.supplier_id as party_id,
    p.name as party_name,
    'purchase_return'::text as entry_type,
    r.id as entry_id,
    r.return_no as reference_no,
    r.return_date as entry_date,
    r.total::numeric as debit,
    0::numeric as credit,
    'مرتجع مشتريات للمورد'::text as description,
    coalesce(r.posted_at, r.created_at) as entry_timestamp
from public.purchase_returns r
where r.status = 'posted'::text;
