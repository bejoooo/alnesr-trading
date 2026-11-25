-- DRAFT ONLY — production reporting views
-- Source definitions are extracted from the current Test schema.
-- Apply only after the new tables, missing columns, and structural FKs are reviewed.
-- No table data is inserted, updated, or deleted by this file.

begin;
set local search_path = public, pg_catalog;

-- Fail closed until all base schema stages are present.
do $preflight$
declare
  v_missing_tables text[];
begin
  select array_agg(x.table_name order by x.table_name)
    into v_missing_tables
  from (values
    ('public.cash_transactions'),
    ('public.products'),
    ('public.stock_movements'),
    ('public.parties'),
    ('public.sales_invoices'),
    ('public.purchase_invoices'),
    ('public.payments'),
    ('public.sales_returns'),
    ('public.purchase_returns'),
    ('public.customer_credit_ledger')
  ) as x(table_name)
  where to_regclass(x.table_name) is null;

  if v_missing_tables is not null then
    raise exception 'Missing base tables for views: %', array_to_string(v_missing_tables, ', ');
  end if;

  if exists (
    select 1
    from (values
      ('cash_transactions','account_method'),
      ('stock_movements','stock_bucket'),
      ('parties','opening_balance_side'),
      ('payments','sales_return_id'),
      ('payments','reversal_of_payment_id'),
      ('payments','posted_at'),
      ('payments','party_account_type'),
      ('payments','payment_code'),
      ('payments','purchase_return_id'),
      ('sales_returns','status'),
      ('sales_returns','posted_at'),
      ('purchase_returns','status'),
      ('purchase_returns','posted_at'),
      ('purchase_returns','credit_generated_total'),
      ('purchase_returns','invoice_due_reduced_total'),
      ('customer_credit_ledger','customer_id'),
      ('customer_credit_ledger','event_type'),
      ('customer_credit_ledger','amount'),
      ('customer_credit_ledger','source_return_id')
    ) as required(table_name,column_name)
    where not exists (
      select 1 from information_schema.columns c
      where c.table_schema='public'
        and c.table_name=required.table_name
        and c.column_name=required.column_name
    )
  ) then
    raise exception 'One or more required view dependency columns are missing';
  end if;
end
$preflight$;

-- cash_balances: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.cash_balances
with (security_invoker=true)
as
 SELECT business_id,
    COALESCE(sum(
        CASE
            WHEN direction = 'in'::text THEN amount
            ELSE - amount
        END), 0::numeric)::numeric(14,2) AS balance
   FROM cash_transactions
  WHERE account_method = 'cash'::text
  GROUP BY business_id;;

-- customer_credit_balances: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.customer_credit_balances
with (security_invoker=true)
as
 SELECT business_id,
    customer_id AS party_id,
    sum(amount)::numeric(14,2) AS available_credit
   FROM customer_credit_ledger
  GROUP BY business_id, customer_id
 HAVING sum(amount) > 0::numeric;;

-- customer_credit_return_balances: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.customer_credit_return_balances
with (security_invoker=true)
as
 SELECT business_id,
    customer_id AS party_id,
    source_return_id,
    sum(amount)::numeric(14,2) AS available_credit,
    sum(amount) FILTER (WHERE event_type = 'return_credit'::text)::numeric(14,2) AS credit_created
   FROM customer_credit_ledger
  GROUP BY business_id, customer_id, source_return_id;;

-- party_account_balances: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.party_account_balances
with (security_invoker=true)
as
 SELECT p.business_id,
    p.id AS party_id,
    p.kind,
    p.name,
    p.phone,
    p.opening_balance,
    COALESCE(s.sales_total, 0::numeric)::numeric(14,2) AS sales_total,
    COALESCE(pi.purchases_total, 0::numeric)::numeric(14,2) AS purchases_total,
    COALESCE(pay.customer_paid, 0::numeric)::numeric(14,2) AS customer_payments,
    COALESCE(pay.supplier_paid, 0::numeric)::numeric(14,2) AS supplier_payments,
    COALESCE(r.returns_total, 0::numeric)::numeric(14,2) AS returns_total,
        CASE
            WHEN p.kind = ANY (ARRAY['customer'::text, 'both'::text]) THEN
            CASE
                WHEN p.opening_balance_side = 'receivable'::text THEN p.opening_balance
                ELSE 0::numeric
            END + COALESCE(s.sales_total, 0::numeric) - COALESCE(pay.customer_paid, 0::numeric) - COALESCE(r.returns_total, 0::numeric) + COALESCE(pay.customer_refunds, 0::numeric)
            ELSE 0::numeric
        END::numeric(14,2) AS customer_net_balance,
        CASE
            WHEN p.kind = ANY (ARRAY['supplier'::text, 'both'::text]) THEN
            CASE
                WHEN p.opening_balance_side = 'payable'::text THEN p.opening_balance
                ELSE 0::numeric
            END + COALESCE(pi.purchases_total, 0::numeric) - COALESCE(pay.supplier_paid, 0::numeric) - COALESCE(pr.purchase_returns_total, 0::numeric)
            ELSE 0::numeric
        END::numeric(14,2) AS supplier_net_balance,
    p.opening_balance_side,
    (COALESCE(pay.customer_paid, 0::numeric) - COALESCE(pay.customer_refunds, 0::numeric))::numeric(14,2) AS customer_net_collected,
    COALESCE(pr.purchase_returns_total, 0::numeric)::numeric(14,2) AS purchase_returns_total
   FROM parties p
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS sales_total
           FROM sales_invoices x
          WHERE x.business_id = p.business_id AND x.customer_id = p.id AND x.status <> 'void'::text) s ON true
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS purchases_total
           FROM purchase_invoices x
          WHERE x.business_id = p.business_id AND x.supplier_id = p.id AND x.status <> 'void'::text) pi ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.sales_return_id IS NULL AND ((EXISTS ( SELECT 1
                       FROM sales_invoices si
                      WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.customer_id = p.id AND si.status <> 'void'::text)) OR x.invoice_id IS NULL AND x.party_account_type = 'customer'::text) THEN
                    CASE
                        WHEN x.direction = 'in'::text THEN x.amount
                        ELSE - x.amount
                    END
                    ELSE 0::numeric
                END) AS customer_paid,
            sum(
                CASE
                    WHEN (EXISTS ( SELECT 1
                       FROM purchase_invoices px
                      WHERE px.id = x.invoice_id AND px.business_id = x.business_id AND px.supplier_id = p.id AND px.status <> 'void'::text)) OR x.invoice_id IS NULL AND x.sales_return_id IS NULL AND x.party_account_type = 'supplier'::text THEN
                    CASE
                        WHEN x.direction = 'out'::text THEN x.amount
                        ELSE - x.amount
                    END
                    ELSE 0::numeric
                END) AS supplier_paid,
            sum(
                CASE
                    WHEN x.sales_return_id IS NOT NULL AND (EXISTS ( SELECT 1
                       FROM sales_returns sr
                      WHERE sr.id = x.sales_return_id AND sr.business_id = x.business_id AND sr.customer_id = p.id AND sr.status <> 'void'::text)) THEN
                    CASE
                        WHEN x.direction = 'out'::text THEN x.amount
                        ELSE - x.amount
                    END
                    ELSE 0::numeric
                END) AS customer_refunds
           FROM payments x
          WHERE x.business_id = p.business_id AND x.party_id = p.id) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(x.refund_total) AS returns_total
           FROM sales_returns x
          WHERE x.business_id = p.business_id AND x.customer_id = p.id AND x.status <> 'void'::text) r ON true
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS purchase_returns_total
           FROM purchase_returns x
          WHERE x.business_id = p.business_id AND x.supplier_id = p.id AND x.status = 'posted'::text) pr ON true;;

-- party_account_statement: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.party_account_statement
with (security_invoker=true)
as
 SELECT p.business_id,
    p.id AS party_id,
    p.name AS party_name,
    'opening_balance'::text AS entry_type,
    NULL::uuid AS entry_id,
    NULL::text AS reference_no,
    p.created_at::date AS entry_date,
        CASE
            WHEN p.opening_balance_side = 'receivable'::text THEN p.opening_balance
            ELSE 0::numeric
        END AS debit,
        CASE
            WHEN p.opening_balance_side = 'payable'::text THEN p.opening_balance
            ELSE 0::numeric
        END AS credit,
    'رصيد افتتاحي'::text AS description,
    p.created_at AS entry_timestamp
   FROM parties p
  WHERE p.opening_balance <> 0::numeric
UNION ALL
 SELECT i.business_id,
    i.customer_id AS party_id,
    p.name AS party_name,
    'sale_invoice'::text AS entry_type,
    i.id AS entry_id,
    i.invoice_no AS reference_no,
    i.invoice_date AS entry_date,
    i.total::numeric AS debit,
    0::numeric AS credit,
    'فاتورة مبيعات'::text AS description,
    i.created_at AS entry_timestamp
   FROM sales_invoices i
     JOIN parties p ON p.id = i.customer_id AND p.business_id = i.business_id
  WHERE i.customer_id IS NOT NULL AND i.status <> 'void'::text
UNION ALL
 SELECT i.business_id,
    i.supplier_id AS party_id,
    p.name AS party_name,
    'purchase_invoice'::text AS entry_type,
    i.id AS entry_id,
    i.invoice_no AS reference_no,
    i.invoice_date AS entry_date,
    0::numeric AS debit,
    i.total::numeric AS credit,
    'فاتورة مشتريات'::text AS description,
    i.created_at AS entry_timestamp
   FROM purchase_invoices i
     JOIN parties p ON p.id = i.supplier_id AND p.business_id = i.business_id
  WHERE i.supplier_id IS NOT NULL AND i.status <> 'void'::text
UNION ALL
 SELECT x.business_id,
    x.party_id,
    p.name AS party_name,
        CASE
            WHEN x.reversal_of_payment_id IS NOT NULL THEN 'payment'::text
            WHEN x.invoice_id IS NULL AND x.sales_return_id IS NULL AND (x.party_account_type = ANY (ARRAY['customer'::text, 'supplier'::text])) THEN
            CASE
                WHEN (EXISTS ( SELECT 1
                   FROM payments rv
                  WHERE rv.reversal_of_payment_id = x.id)) THEN 'reversed_standalone_payment'::text
                ELSE 'standalone_payment'::text
            END
            ELSE 'payment'::text
        END AS entry_type,
    x.id AS entry_id,
        CASE
            WHEN x.reversal_of_payment_id IS NOT NULL THEN COALESCE(NULLIF(concat_ws(' · '::text, original.payment_code, original.reference), ''::text), 'بدون كود'::text)
            ELSE concat_ws(' · '::text, x.payment_code, x.reference)
        END AS reference_no,
    x.payment_date AS entry_date,
        CASE
            WHEN x.direction = 'out'::text THEN x.amount
            ELSE 0::numeric
        END AS debit,
        CASE
            WHEN x.direction = 'in'::text THEN x.amount
            ELSE 0::numeric
        END AS credit,
        CASE
            WHEN x.reversal_of_payment_id IS NOT NULL THEN 'قيد عكسي لدفعة'::text
            WHEN x.invoice_id IS NULL AND x.sales_return_id IS NULL THEN
            CASE
                WHEN x.party_account_type = 'customer'::text THEN 'تحصيل مستقل من عميل'::text
                WHEN x.direction = 'in'::text THEN 'استلام رصيد دائن من مورد'::text
                ELSE 'سداد مستقل لمورد'::text
            END
            ELSE COALESCE(x.notes, 'دفعة'::text)
        END AS description,
    COALESCE(x.posted_at, x.created_at) AS entry_timestamp
   FROM payments x
     JOIN parties p ON p.id = x.party_id AND p.business_id = x.business_id
     LEFT JOIN payments original ON original.id = x.reversal_of_payment_id AND original.business_id = x.business_id
  WHERE x.party_id IS NOT NULL AND (x.sales_return_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM sales_returns r
          WHERE r.id = x.sales_return_id AND r.business_id = x.business_id AND r.status <> 'void'::text)) OR x.sales_return_id IS NULL AND x.invoice_id IS NOT NULL AND ((EXISTS ( SELECT 1
           FROM sales_invoices si
          WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.status <> 'void'::text)) OR (EXISTS ( SELECT 1
           FROM purchase_invoices pi
          WHERE pi.id = x.invoice_id AND pi.business_id = x.business_id AND pi.status <> 'void'::text))) OR x.sales_return_id IS NULL AND x.invoice_id IS NULL AND (x.party_account_type = ANY (ARRAY['customer'::text, 'supplier'::text])))
UNION ALL
 SELECT r.business_id,
    r.customer_id AS party_id,
    p.name AS party_name,
    'sales_return'::text AS entry_type,
    r.id AS entry_id,
    r.return_no AS reference_no,
    r.return_date AS entry_date,
    0::numeric AS debit,
    r.refund_total::numeric AS credit,
    'مرتجع مبيعات'::text AS description,
    COALESCE(r.posted_at, r.created_at) AS entry_timestamp
   FROM sales_returns r
     JOIN parties p ON p.id = r.customer_id AND p.business_id = r.business_id
  WHERE r.customer_id IS NOT NULL AND r.status <> 'void'::text
UNION ALL
 SELECT r.business_id,
    r.supplier_id AS party_id,
    p.name AS party_name,
    'purchase_return'::text AS entry_type,
    r.id AS entry_id,
    r.return_no AS reference_no,
    r.return_date AS entry_date,
    r.total::numeric AS debit,
    0::numeric AS credit,
    'مرتجع مشتريات للمورد'::text AS description,
    COALESCE(r.posted_at, r.created_at) AS entry_timestamp
   FROM purchase_returns r
     JOIN parties p ON p.id = r.supplier_id AND p.business_id = r.business_id
  WHERE r.status = 'posted'::text;;

-- product_stock_balances: replace existing view or create it if absent; preserve security_invoker.
create or replace view public.product_stock_balances
with (security_invoker=true)
as
 SELECT p.business_id,
    p.id AS product_id,
    p.code,
    p.name,
    p.unit,
    p.minimum_stock,
    COALESCE(sum(sm.quantity_delta) FILTER (WHERE sm.stock_bucket = 'sellable'::text), 0::numeric)::numeric(14,3) AS quantity_on_hand,
    p.average_cost,
    (COALESCE(sum(sm.quantity_delta) FILTER (WHERE sm.stock_bucket = 'sellable'::text), 0::numeric) * p.average_cost)::numeric(14,2) AS stock_value,
    count(sm.id) FILTER (WHERE sm.stock_bucket = 'sellable'::text) > 0 AND COALESCE(sum(sm.quantity_delta) FILTER (WHERE sm.stock_bucket = 'sellable'::text), 0::numeric) <= p.minimum_stock AS below_minimum,
    count(sm.id) FILTER (WHERE sm.stock_bucket = 'sellable'::text) > 0 AS has_stock_history,
    count(sm.id) FILTER (WHERE sm.stock_bucket = 'sellable'::text) > 0 AND COALESCE(sum(sm.quantity_delta) FILTER (WHERE sm.stock_bucket = 'sellable'::text), 0::numeric) <= 0::numeric AS out_of_stock,
    COALESCE(sum(sm.quantity_delta) FILTER (WHERE sm.stock_bucket = 'damaged'::text), 0::numeric)::numeric(14,3) AS damaged_quantity,
    COALESCE(sum(sm.quantity_delta), 0::numeric)::numeric(14,3) AS total_stock_quantity
   FROM products p
     LEFT JOIN stock_movements sm ON sm.business_id = p.business_id AND sm.product_id = p.id
  WHERE p.is_active = true
  GROUP BY p.business_id, p.id, p.code, p.name, p.unit, p.minimum_stock, p.average_cost;;

-- The two credit views are new in Production. Match Test's restricted ACL:
-- authenticated may read through RLS; anon and PUBLIC receive no access.
revoke all on table public.customer_credit_balances,
  public.customer_credit_return_balances from public, anon;
grant select on table public.customer_credit_balances,
  public.customer_credit_return_balances to authenticated;
grant all on table public.customer_credit_balances,
  public.customer_credit_return_balances to service_role;

commit;

-- Post-stage read-only checks:
-- 1) all six views exist and have security_invoker=true.
-- 2) column names/order/types match the Test contract.
-- 3) ACLs for the two new views are authenticated SELECT + service_role only.
-- 4) run balance reconciliation against controlled fixtures before accepting results.
-- This draft has not been executed on Test or Production.
