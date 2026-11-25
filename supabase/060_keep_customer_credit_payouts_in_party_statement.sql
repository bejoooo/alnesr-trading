-- Keep payout payments in the main statement because they change the customer's account balance.
CREATE OR REPLACE VIEW public.party_account_statement WITH (security_invoker=true) AS
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
