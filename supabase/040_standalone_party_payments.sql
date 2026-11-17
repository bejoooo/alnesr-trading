alter table public.payments add column if not exists party_account_type text;
alter table public.payments add constraint payments_party_account_type_check check (party_account_type is null or party_account_type in ('customer','supplier'));
alter table public.cash_transactions add column if not exists payment_id uuid;
alter table public.cash_transactions add constraint cash_transactions_payment_id_fkey foreign key(payment_id) references public.payments(id) on delete restrict;
create unique index if not exists cash_transactions_one_per_payment on public.cash_transactions(payment_id) where payment_id is not null;
CREATE OR REPLACE FUNCTION public.record_standalone_party_payment(p_business_id uuid, p_party_id uuid, p_account_type text, p_amount numeric, p_payment_date date DEFAULT CURRENT_DATE, p_method text DEFAULT 'cash'::text, p_reference text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_party public.parties%rowtype;
 v_direction text;
 v_payment_id uuid;
 v_cash_balance numeric(14,2);
begin
 if auth.uid() is null or not public.has_business_permission(p_business_id,'payments.create') then
  raise exception 'Not authorized to record payments';
 end if;
 if p_account_type not in ('customer','supplier') then
  raise exception 'Choose whether this payment belongs to the customer or supplier account';
 end if;
 if p_amount is null or p_amount<=0 then raise exception 'Payment must be positive'; end if;
 p_method:=lower(btrim(coalesce(p_method,'cash')));
 if p_method not in ('cash','bank_transfer','instapay','other') then
  raise exception 'Unsupported payment method';
 end if;
 if p_account_type='customer' then
  if not public.has_business_permission(p_business_id,'sales.view') then raise exception 'Not authorized to access customer accounts'; end if;
  v_direction:='in';
 else
  if not public.has_business_permission(p_business_id,'purchases.view') then raise exception 'Not authorized to access supplier accounts'; end if;
  v_direction:='out';
 end if;
 select * into v_party from public.parties
 where id=p_party_id and business_id=p_business_id for update;
 if not found then raise exception 'Party not found in this business'; end if;
 if p_account_type='customer' and v_party.kind not in ('customer','both') then
  raise exception 'This account is not configured as a customer';
 end if;
 if p_account_type='supplier' and v_party.kind not in ('supplier','both') then
  raise exception 'This account is not configured as a supplier';
 end if;
 if p_method='cash' then
  if not public.has_business_permission(p_business_id,'cash.create') then raise exception 'Not authorized to change cash balance'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_cash_balance from public.cash_transactions where business_id=p_business_id;
  if v_direction='out' and v_cash_balance<p_amount then
   raise exception 'Insufficient cash balance for this supplier payment';
  end if;
 end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by)
 values(p_business_id,p_party_id,null,p_account_type,v_direction,p_amount,coalesce(p_payment_date,current_date),p_method,
  nullif(btrim(p_reference),''),nullif(btrim(p_notes),''),auth.uid())
 returning id into v_payment_id;
 if p_method='cash' then
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,payment_id)
  values(p_business_id,coalesce(p_payment_date,current_date),v_direction,'other',p_amount,p_party_id,null,
   case when p_account_type='customer' then 'تحصيل مستقل من عميل' else 'سداد مستقل لمورد' end,
   nullif(btrim(p_notes),''),auth.uid(),v_payment_id);
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'standalone_payment','payment',v_payment_id,
  jsonb_build_object('party_id',p_party_id,'account_type',p_account_type,'direction',v_direction,'amount',p_amount,'method',p_method));
 return v_payment_id;
end;
$function$

CREATE OR REPLACE FUNCTION public.owner_reverse_standalone_party_payment(p_business_id uuid, p_payment_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
 v_payment public.payments%rowtype;
 v_cash public.cash_transactions%rowtype;
 v_reversal_id uuid;
 v_cash_balance numeric(14,2);
begin
 if auth.uid() is null or not exists(
  select 1 from public.business_members
  where business_id=p_business_id and user_id=auth.uid() and active=true and role='owner'
 ) then raise exception 'Only the active business owner can reverse a standalone payment'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_business_id::text,0));
 select * into v_payment from public.payments
 where id=p_payment_id and business_id=p_business_id and invoice_id is null
  and sales_return_id is null and party_account_type in ('customer','supplier')
  and reversal_of_payment_id is null for update;
 if not found then raise exception 'Standalone payment not found'; end if;
 if exists(select 1 from public.payments where reversal_of_payment_id=v_payment.id) then
  raise exception 'This payment has already been reversed';
 end if;
 if lower(v_payment.method)='cash' then
  select * into v_cash from public.cash_transactions
  where business_id=p_business_id and payment_id=v_payment.id for update;
  if not found or v_cash.amount<>v_payment.amount or v_cash.direction<>v_payment.direction then
   raise exception 'The payment does not reconcile with its cash ledger entry';
  end if;
  select coalesce(sum(case when direction='in' then amount else -amount end),0)
   into v_cash_balance from public.cash_transactions where business_id=p_business_id;
  if v_cash.direction='in' and v_cash_balance<v_cash.amount then
   raise exception 'Insufficient cash balance to reverse this receipt';
  end if;
 else
  if exists(select 1 from public.cash_transactions where business_id=p_business_id and payment_id=v_payment.id) then
   raise exception 'A non-cash payment unexpectedly has a cash ledger entry';
  end if;
 end if;
 insert into public.payments(business_id,party_id,invoice_id,party_account_type,direction,amount,payment_date,method,reference,notes,created_by,reversal_of_payment_id)
 values(p_business_id,v_payment.party_id,null,v_payment.party_account_type,
  case when v_payment.direction='in' then 'out' else 'in' end,
  v_payment.amount,current_date,v_payment.method,
  'عكس دفعة '||coalesce(v_payment.reference,v_payment.id::text),
  'قيد عكسي لدفعة مستقلة',auth.uid(),v_payment.id)
 returning id into v_reversal_id;
 if lower(v_payment.method)='cash' then
  insert into public.cash_transactions(business_id,transaction_date,direction,transaction_type,amount,party_id,invoice_id,
   reason,notes,created_by,reversal_of_transaction_id,payment_id)
  values(p_business_id,current_date,case when v_cash.direction='in' then 'out' else 'in' end,
   case when v_cash.direction='in' then 'other' else 'deposit' end,
   v_cash.amount,v_cash.party_id,null,'عكس دفعة مستقلة', 'عكس حركة الخزنة الأصلية رقم '||v_cash.id,
   auth.uid(),v_cash.id,v_reversal_id);
 end if;
 insert into public.audit_log(business_id,actor_id,action,entity_type,entity_id,details)
 values(p_business_id,auth.uid(),'reverse_standalone_payment','payment',v_payment.id,
  jsonb_build_object('reversal_payment_id',v_reversal_id,'amount',v_payment.amount,'method',v_payment.method));
 return v_reversal_id;
end;
$function$

drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated using ((has_business_permission(business_id, 'payments.view'::text) AND ((EXISTS ( SELECT 1
   FROM sales_invoices si
  WHERE ((si.id = payments.invoice_id) AND (si.business_id = payments.business_id) AND has_business_permission(payments.business_id, 'sales.view'::text)))) OR (EXISTS ( SELECT 1
   FROM purchase_invoices pi
  WHERE ((pi.id = payments.invoice_id) AND (pi.business_id = payments.business_id) AND has_business_permission(payments.business_id, 'purchases.view'::text)))) OR ((invoice_id IS NULL) AND (party_account_type = 'customer'::text) AND has_business_permission(business_id, 'sales.view'::text)) OR ((invoice_id IS NULL) AND (party_account_type = 'supplier'::text) AND has_business_permission(business_id, 'purchases.view'::text)) OR ((invoice_id IS NULL) AND (party_account_type IS NULL) AND has_business_role(business_id, ARRAY['owner'::text, 'admin'::text])))));
revoke all on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) from public,anon;
grant execute on function public.record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text) to authenticated;
revoke all on function public.owner_reverse_standalone_party_payment(uuid,uuid) from public,anon;
grant execute on function public.owner_reverse_standalone_party_payment(uuid,uuid) to authenticated;
create or replace view public.party_account_balances with (security_invoker=true) as  SELECT p.business_id,
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
            END + COALESCE(pi.purchases_total, 0::numeric) - COALESCE(pay.supplier_paid, 0::numeric)
            ELSE 0::numeric
        END::numeric(14,2) AS supplier_net_balance,
    p.opening_balance_side
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
          WHERE x.business_id = p.business_id AND x.customer_id = p.id AND x.status <> 'void'::text) r ON true;;
create or replace view public.daily_business_summary with (security_invoker=true) as  WITH report_dates AS (
         SELECT sales_invoices.business_id,
            sales_invoices.invoice_date AS report_date
           FROM sales_invoices
          WHERE sales_invoices.status <> 'void'::text
        UNION
         SELECT purchase_invoices.business_id,
            purchase_invoices.invoice_date
           FROM purchase_invoices
          WHERE purchase_invoices.status <> 'void'::text
        UNION
         SELECT expenses.business_id,
            expenses.expense_date
           FROM expenses
          WHERE expenses.status <> 'void'::text
        UNION
         SELECT cash_transactions.business_id,
            cash_transactions.transaction_date
           FROM cash_transactions
        UNION
         SELECT p_1.business_id,
            p_1.payment_date
           FROM payments p_1
          WHERE (p_1.invoice_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_invoices si
                  WHERE si.id = p_1.invoice_id AND si.business_id = p_1.business_id AND si.status <> 'void'::text)) OR (EXISTS ( SELECT 1
                   FROM purchase_invoices pi
                  WHERE pi.id = p_1.invoice_id AND pi.business_id = p_1.business_id AND pi.status <> 'void'::text))) AND (p_1.sales_return_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_returns sr
                  WHERE sr.id = p_1.sales_return_id AND sr.business_id = p_1.business_id AND sr.status <> 'void'::text)))
        )
 SELECT d.business_id,
    d.report_date,
    COALESCE(s.sales_total, 0::numeric)::numeric(14,2) AS sales_total,
    COALESCE(pay.sales_collected, 0::numeric)::numeric(14,2) AS sales_collected,
    COALESCE(s.sales_due, 0::numeric)::numeric(14,2) AS sales_outstanding,
    COALESCE(p.purchases_total, 0::numeric)::numeric(14,2) AS purchases_total,
    COALESCE(pay.purchases_paid, 0::numeric)::numeric(14,2) AS purchases_paid,
    COALESCE(e.expenses_total, 0::numeric)::numeric(14,2) AS expenses_total,
    COALESCE(c.cash_in, 0::numeric)::numeric(14,2) AS cash_in,
    COALESCE(c.cash_out, 0::numeric)::numeric(14,2) AS cash_out
   FROM report_dates d
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS sales_total,
            sum(x.due_total) AS sales_due
           FROM sales_invoices x
          WHERE x.business_id = d.business_id AND x.invoice_date = d.report_date AND x.status <> 'void'::text) s ON true
     LEFT JOIN LATERAL ( SELECT sum(x.total) AS purchases_total
           FROM purchase_invoices x
          WHERE x.business_id = d.business_id AND x.invoice_date = d.report_date AND x.status <> 'void'::text) p ON true
     LEFT JOIN LATERAL ( SELECT sum(x.amount) AS expenses_total
           FROM expenses x
          WHERE x.business_id = d.business_id AND x.expense_date = d.report_date AND x.status <> 'void'::text) e ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text AND x.sales_return_id IS NULL AND ((EXISTS ( SELECT 1
                       FROM sales_invoices si
                      WHERE si.id = x.invoice_id AND si.business_id = x.business_id AND si.status <> 'void'::text)) OR x.invoice_id IS NULL AND x.party_account_type = 'customer'::text) THEN x.amount
                    ELSE 0::numeric
                END) AS sales_collected,
            sum(
                CASE
                    WHEN x.direction = 'out'::text AND ((EXISTS ( SELECT 1
                       FROM purchase_invoices pi
                      WHERE pi.id = x.invoice_id AND pi.business_id = x.business_id AND pi.status <> 'void'::text)) OR x.invoice_id IS NULL AND x.sales_return_id IS NULL AND x.party_account_type = 'supplier'::text) THEN x.amount
                    ELSE 0::numeric
                END) AS purchases_paid
           FROM payments x
          WHERE x.business_id = d.business_id AND x.payment_date = d.report_date AND (x.sales_return_id IS NULL OR (EXISTS ( SELECT 1
                   FROM sales_returns sr
                  WHERE sr.id = x.sales_return_id AND sr.business_id = x.business_id AND sr.status <> 'void'::text)))) pay ON true
     LEFT JOIN LATERAL ( SELECT sum(
                CASE
                    WHEN x.direction = 'in'::text THEN x.amount
                    ELSE 0::numeric
                END) AS cash_in,
            sum(
                CASE
                    WHEN x.direction = 'out'::text THEN x.amount
                    ELSE 0::numeric
                END) AS cash_out
           FROM cash_transactions x
          WHERE x.business_id = d.business_id AND x.transaction_date = d.report_date) c ON true;;
create or replace view public.party_account_statement with (security_invoker=true) as  SELECT p.business_id,
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
    'رصيد افتتاحي'::text AS description
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
    'فاتورة مبيعات'::text AS description
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
    'فاتورة مشتريات'::text AS description
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
    x.reference AS reference_no,
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
                ELSE 'سداد مستقل لمورد'::text
            END
            ELSE COALESCE(x.notes, 'دفعة'::text)
        END AS description
   FROM payments x
     JOIN parties p ON p.id = x.party_id AND p.business_id = x.business_id
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
    'مرتجع مبيعات'::text AS description
   FROM sales_returns r
     JOIN parties p ON p.id = r.customer_id AND p.business_id = r.business_id
  WHERE r.customer_id IS NOT NULL AND r.status <> 'void'::text;;