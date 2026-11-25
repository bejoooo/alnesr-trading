# مواصفات الجداول التشغيلية السبعة المطلوبة لترقية Preview

تاريخ الفحص: 25 نوفمبر 2026  
المصدر: مخطط Test الحالي `hxwcjbmlxbqrurrmjbpf` فقط.  
الغرض: مرجع هندسي لإعادة بناء الجداول في Production؛ ليس Migration جاهزة للتشغيل.

## ملخص

- سبعة جداول تشغيلية غير موجودة في Production.
- تمت قراءة جميع الأعمدة والقيود والفهارس وسياسات RLS من Test.
- لا يتم نقل أي صفوف من Test.
- مواصفات Test ليست نهائية كما هي؛ يلزم تقوية علاقات same-business قبل استخدامها في Production.

## `customer_credit_ledger`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `id` | `uuid` | لا | `gen_random_uuid()` |
| `business_id` | `uuid` | لا | — |
| `customer_id` | `uuid` | لا | — |
| `source_return_id` | `uuid` | نعم | — |
| `invoice_id` | `uuid` | نعم | — |
| `payment_id` | `uuid` | نعم | — |
| `event_type` | `text` | لا | — |
| `amount` | `numeric (precision defined in source)` | لا | — |
| `reversal_of_id` | `uuid` | نعم | — |
| `created_by` | `uuid` | نعم | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |

### القيود
- **C** `customer_credit_ledger_amount_check`: `CHECK (amount <> 0::numeric)`
- **C** `customer_credit_ledger_event_type_check`: `CHECK (event_type = ANY (ARRAY['return_credit'::text, 'invoice_application'::text, 'payout'::text, 'reversal'::text]))`
- **F** `customer_credit_ledger_business_id_fkey`: `FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE`
- **F** `customer_credit_ledger_created_by_fkey`: `FOREIGN KEY (created_by) REFERENCES auth.users(id)`
- **F** `customer_credit_ledger_customer_id_fkey`: `FOREIGN KEY (customer_id) REFERENCES parties(id) ON DELETE RESTRICT`
- **F** `customer_credit_ledger_invoice_id_fkey`: `FOREIGN KEY (invoice_id) REFERENCES sales_invoices(id) ON DELETE RESTRICT`
- **F** `customer_credit_ledger_payment_id_fkey`: `FOREIGN KEY (payment_id) REFERENCES payments(id) ON DELETE RESTRICT`
- **F** `customer_credit_ledger_reversal_of_id_fkey`: `FOREIGN KEY (reversal_of_id) REFERENCES customer_credit_ledger(id) ON DELETE RESTRICT`
- **F** `customer_credit_ledger_source_return_id_fkey`: `FOREIGN KEY (source_return_id) REFERENCES sales_returns(id) ON DELETE RESTRICT`
- **P** `customer_credit_ledger_pkey`: `PRIMARY KEY (id)`
- **U** `customer_credit_business_id_id_uk`: `UNIQUE (business_id, id)`
- **U** `customer_credit_reversal_unique`: `UNIQUE (reversal_of_id)`

### الفهارس
- `customer_credit_business_id_id_uk`: `CREATE UNIQUE INDEX customer_credit_business_id_id_uk ON public.customer_credit_ledger USING btree (business_id, id)`
- `customer_credit_customer_idx`: `CREATE INDEX customer_credit_customer_idx ON public.customer_credit_ledger USING btree (business_id, customer_id, created_at)`
- `customer_credit_ledger_created_by_idx`: `CREATE INDEX customer_credit_ledger_created_by_idx ON public.customer_credit_ledger USING btree (created_by)`
- `customer_credit_ledger_customer_id_idx`: `CREATE INDEX customer_credit_ledger_customer_id_idx ON public.customer_credit_ledger USING btree (customer_id)`
- `customer_credit_ledger_invoice_id_idx`: `CREATE INDEX customer_credit_ledger_invoice_id_idx ON public.customer_credit_ledger USING btree (invoice_id)`
- `customer_credit_ledger_payment_id_idx`: `CREATE INDEX customer_credit_ledger_payment_id_idx ON public.customer_credit_ledger USING btree (payment_id)`
- `customer_credit_ledger_pkey`: `CREATE UNIQUE INDEX customer_credit_ledger_pkey ON public.customer_credit_ledger USING btree (id)`
- `customer_credit_ledger_source_return_id_idx`: `CREATE INDEX customer_credit_ledger_source_return_id_idx ON public.customer_credit_ledger USING btree (source_return_id)`
- `customer_credit_reversal_unique`: `CREATE UNIQUE INDEX customer_credit_reversal_unique ON public.customer_credit_ledger USING btree (reversal_of_id)`
- `customer_credit_source_idx`: `CREATE INDEX customer_credit_source_idx ON public.customer_credit_ledger USING btree (business_id, source_return_id)`

### سياسات RLS
- `customer_credit_ledger_read` (SELECT, {authenticated}): USING `(has_business_permission(business_id, 'sales.view'::text) OR has_business_permission(business_id, 'parties.view'::text))`; WITH CHECK `—`

## `operation_counters`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `business_id` | `uuid` | لا | — |
| `operation_type` | `text` | لا | — |
| `last_number` | `bigint` | لا | `0` |
| `updated_at` | `timestamp with time zone` | لا | `now()` |

### القيود
- **C** `operation_counters_last_number_check`: `CHECK (last_number >= 0)`
- **F** `operation_counters_business_id_fkey`: `FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE`
- **P** `operation_counters_pkey`: `PRIMARY KEY (business_id, operation_type)`

### الفهارس
- `operation_counters_pkey`: `CREATE UNIQUE INDEX operation_counters_pkey ON public.operation_counters USING btree (business_id, operation_type)`

### سياسات RLS
لا توجد سياسات (جدول operation_counters معزول ويُدار عبر الدوال فقط)

## `purchase_invoice_cost_snapshots`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `business_id` | `uuid` | لا | — |
| `invoice_id` | `uuid` | لا | — |
| `product_id` | `uuid` | لا | — |
| `average_cost_before` | `numeric (precision defined in source)` | لا | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |

### القيود
- **F** `purchase_invoice_cost_snapshots_invoice_id_fkey`: `FOREIGN KEY (invoice_id) REFERENCES purchase_invoices(id) ON DELETE CASCADE`
- **F** `purchase_invoice_cost_snapshots_product_id_fkey`: `FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT`
- **P** `purchase_invoice_cost_snapshots_pkey`: `PRIMARY KEY (invoice_id, product_id)`

### الفهارس
- `purchase_invoice_cost_snapshots_pkey`: `CREATE UNIQUE INDEX purchase_invoice_cost_snapshots_pkey ON public.purchase_invoice_cost_snapshots USING btree (invoice_id, product_id)`
- `purchase_invoice_cost_snapshots_product_id_idx`: `CREATE INDEX purchase_invoice_cost_snapshots_product_id_idx ON public.purchase_invoice_cost_snapshots USING btree (product_id)`

### سياسات RLS
- `owner_read_purchase_cost_snapshots` (SELECT, {authenticated}): USING `has_business_role(business_id, ARRAY['owner'::text])`; WITH CHECK `—`

## `purchase_return_items`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `id` | `uuid` | لا | `gen_random_uuid()` |
| `business_id` | `uuid` | لا | — |
| `return_id` | `uuid` | لا | — |
| `purchase_item_id` | `uuid` | لا | — |
| `product_id` | `uuid` | لا | — |
| `quantity` | `numeric (precision defined in source)` | لا | — |
| `condition` | `text` | لا | — |
| `unit_cost` | `numeric (precision defined in source)` | لا | — |
| `line_total` | `numeric (precision defined in source)` | لا | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |

### القيود
- **C** `purchase_return_items_condition_check`: `CHECK (condition = ANY (ARRAY['good'::text, 'damaged'::text]))`
- **C** `purchase_return_items_line_total_check`: `CHECK (line_total >= 0::numeric)`
- **C** `purchase_return_items_quantity_check`: `CHECK (quantity > 0::numeric)`
- **C** `purchase_return_items_unit_cost_check`: `CHECK (unit_cost >= 0::numeric)`
- **F** `purchase_return_items_business_id_fkey`: `FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE`
- **F** `purchase_return_items_product_id_fkey`: `FOREIGN KEY (product_id) REFERENCES products(id)`
- **F** `purchase_return_items_purchase_item_id_fkey`: `FOREIGN KEY (purchase_item_id) REFERENCES purchase_items(id)`
- **F** `purchase_return_items_return_id_fkey`: `FOREIGN KEY (return_id) REFERENCES purchase_returns(id) ON DELETE CASCADE`
- **P** `purchase_return_items_pkey`: `PRIMARY KEY (id)`

### الفهارس
- `purchase_return_items_pkey`: `CREATE UNIQUE INDEX purchase_return_items_pkey ON public.purchase_return_items USING btree (id)`
- `purchase_return_items_product_id_idx`: `CREATE INDEX purchase_return_items_product_id_idx ON public.purchase_return_items USING btree (product_id)`
- `purchase_return_items_purchase_item_id_idx`: `CREATE INDEX purchase_return_items_purchase_item_id_idx ON public.purchase_return_items USING btree (purchase_item_id)`
- `purchase_return_items_purchase_item_idx`: `CREATE INDEX purchase_return_items_purchase_item_idx ON public.purchase_return_items USING btree (business_id, purchase_item_id)`
- `purchase_return_items_return_id_idx`: `CREATE INDEX purchase_return_items_return_id_idx ON public.purchase_return_items USING btree (return_id)`
- `purchase_return_items_return_idx`: `CREATE INDEX purchase_return_items_return_idx ON public.purchase_return_items USING btree (business_id, return_id)`

### سياسات RLS
- `purchase_return_items_read` (SELECT, {authenticated}): USING `has_business_permission(business_id, 'purchases.view'::text)`; WITH CHECK `—`

## `purchase_returns`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `id` | `uuid` | لا | `gen_random_uuid()` |
| `business_id` | `uuid` | لا | — |
| `return_no` | `text` | لا | — |
| `purchase_invoice_id` | `uuid` | لا | — |
| `supplier_id` | `uuid` | لا | — |
| `return_date` | `date` | لا | `CURRENT_DATE` |
| `total` | `numeric (precision defined in source)` | لا | `0` |
| `notes` | `text` | نعم | — |
| `created_by` | `uuid` | نعم | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |
| `posted_at` | `timestamp with time zone` | لا | `clock_timestamp()` |
| `status` | `text` | لا | `'posted'::text` |
| `credit_generated_total` | `numeric (precision defined in source)` | لا | `0` |
| `invoice_due_reduced_total` | `numeric (precision defined in source)` | نعم | — |

### القيود
- **C** `purchase_returns_credit_generated_total_check`: `CHECK (credit_generated_total >= 0::numeric)`
- **C** `purchase_returns_status_check`: `CHECK (status = ANY (ARRAY['posted'::text, 'void'::text]))`
- **C** `purchase_returns_total_check`: `CHECK (total >= 0::numeric)`
- **F** `purchase_returns_business_id_fkey`: `FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE`
- **F** `purchase_returns_purchase_invoice_id_fkey`: `FOREIGN KEY (purchase_invoice_id) REFERENCES purchase_invoices(id)`
- **F** `purchase_returns_supplier_id_fkey`: `FOREIGN KEY (supplier_id) REFERENCES parties(id)`
- **P** `purchase_returns_pkey`: `PRIMARY KEY (id)`
- **U** `purchase_returns_business_id_id_key`: `UNIQUE (business_id, id)`
- **U** `purchase_returns_business_id_return_no_key`: `UNIQUE (business_id, return_no)`

### الفهارس
- `purchase_returns_business_id_id_key`: `CREATE UNIQUE INDEX purchase_returns_business_id_id_key ON public.purchase_returns USING btree (business_id, id)`
- `purchase_returns_business_id_return_no_key`: `CREATE UNIQUE INDEX purchase_returns_business_id_return_no_key ON public.purchase_returns USING btree (business_id, return_no)`
- `purchase_returns_invoice_idx`: `CREATE INDEX purchase_returns_invoice_idx ON public.purchase_returns USING btree (business_id, purchase_invoice_id, status)`
- `purchase_returns_pkey`: `CREATE UNIQUE INDEX purchase_returns_pkey ON public.purchase_returns USING btree (id)`
- `purchase_returns_purchase_invoice_id_idx`: `CREATE INDEX purchase_returns_purchase_invoice_id_idx ON public.purchase_returns USING btree (purchase_invoice_id)`
- `purchase_returns_supplier_id_idx`: `CREATE INDEX purchase_returns_supplier_id_idx ON public.purchase_returns USING btree (supplier_id)`
- `purchase_returns_supplier_idx`: `CREATE INDEX purchase_returns_supplier_idx ON public.purchase_returns USING btree (business_id, supplier_id, status)`

### سياسات RLS
- `purchase_returns_read` (SELECT, {authenticated}): USING `has_business_permission(business_id, 'purchases.view'::text)`; WITH CHECK `—`

## `stock_adjustment_cost_snapshots`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `business_id` | `uuid` | لا | — |
| `movement_id` | `uuid` | لا | — |
| `product_id` | `uuid` | لا | — |
| `average_cost_before` | `numeric (precision defined in source)` | لا | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |

### القيود
- **F** `stock_adjustment_cost_snapshots_movement_id_fkey`: `FOREIGN KEY (movement_id) REFERENCES stock_movements(id) ON DELETE RESTRICT`
- **F** `stock_adjustment_cost_snapshots_product_id_fkey`: `FOREIGN KEY (product_id) REFERENCES products(id) ON DELETE RESTRICT`
- **P** `stock_adjustment_cost_snapshots_pkey`: `PRIMARY KEY (business_id, movement_id)`

### الفهارس
- `stock_adjustment_cost_snapshots_movement_id_idx`: `CREATE INDEX stock_adjustment_cost_snapshots_movement_id_idx ON public.stock_adjustment_cost_snapshots USING btree (movement_id)`
- `stock_adjustment_cost_snapshots_pkey`: `CREATE UNIQUE INDEX stock_adjustment_cost_snapshots_pkey ON public.stock_adjustment_cost_snapshots USING btree (business_id, movement_id)`
- `stock_adjustment_cost_snapshots_product_id_idx`: `CREATE INDEX stock_adjustment_cost_snapshots_product_id_idx ON public.stock_adjustment_cost_snapshots USING btree (product_id)`

### سياسات RLS
- `owner_read_stock_adjustment_cost_snapshots` (SELECT, {authenticated}): USING `has_business_role(business_id, ARRAY['owner'::text])`; WITH CHECK `—`

## `treasury_transfers`

### الأعمدة
| العمود | النوع | NULL | Default |
|---|---|---|---|
| `id` | `uuid` | لا | `gen_random_uuid()` |
| `business_id` | `uuid` | لا | — |
| `transfer_date` | `date` | لا | `CURRENT_DATE` |
| `source_method` | `text` | لا | — |
| `destination_method` | `text` | لا | — |
| `amount` | `numeric (precision defined in source)` | لا | — |
| `notes` | `text` | نعم | — |
| `created_by` | `uuid` | نعم | — |
| `created_at` | `timestamp with time zone` | لا | `now()` |
| `transfer_code` | `text` | لا | — |
| `reversal_of_transfer_id` | `uuid` | نعم | — |

### القيود
- **C** `treasury_transfer_distinct_methods`: `CHECK (source_method <> destination_method)`
- **C** `treasury_transfers_amount_check`: `CHECK (amount > 0::numeric)`
- **C** `treasury_transfers_destination_method_check`: `CHECK (destination_method = ANY (ARRAY['cash'::text, 'instapay'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'other'::text]))`
- **C** `treasury_transfers_no_self_reversal`: `CHECK (reversal_of_transfer_id IS NULL OR reversal_of_transfer_id <> id)`
- **C** `treasury_transfers_source_method_check`: `CHECK (source_method = ANY (ARRAY['cash'::text, 'instapay'::text, 'bank_transfer'::text, 'mobile_wallet'::text, 'other'::text]))`
- **F** `treasury_transfers_business_id_fkey`: `FOREIGN KEY (business_id) REFERENCES businesses(id) ON DELETE CASCADE`
- **F** `treasury_transfers_created_by_fkey`: `FOREIGN KEY (created_by) REFERENCES auth.users(id)`
- **F** `treasury_transfers_reversal_same_business_fkey`: `FOREIGN KEY (business_id, reversal_of_transfer_id) REFERENCES treasury_transfers(business_id, id) ON DELETE RESTRICT`
- **P** `treasury_transfers_pkey`: `PRIMARY KEY (id)`
- **U** `treasury_transfer_business_id_id_unique`: `UNIQUE (business_id, id)`

### الفهارس
- `treasury_transfer_business_id_id_unique`: `CREATE UNIQUE INDEX treasury_transfer_business_id_id_unique ON public.treasury_transfers USING btree (business_id, id)`
- `treasury_transfers_business_date_idx`: `CREATE INDEX treasury_transfers_business_date_idx ON public.treasury_transfers USING btree (business_id, transfer_date DESC, created_at DESC)`
- `treasury_transfers_created_by_idx`: `CREATE INDEX treasury_transfers_created_by_idx ON public.treasury_transfers USING btree (created_by)`
- `treasury_transfers_one_reversal_per_transfer`: `CREATE UNIQUE INDEX treasury_transfers_one_reversal_per_transfer ON public.treasury_transfers USING btree (business_id, reversal_of_transfer_id) WHERE (reversal_of_transfer_id IS NOT NULL)`
- `treasury_transfers_pkey`: `CREATE UNIQUE INDEX treasury_transfers_pkey ON public.treasury_transfers USING btree (id)`
- `treasury_transfers_transfer_code_uq`: `CREATE UNIQUE INDEX treasury_transfers_transfer_code_uq ON public.treasury_transfers USING btree (business_id, transfer_code)`

### سياسات RLS
- `treasury_transfers_read` (SELECT, {authenticated}): USING `has_business_permission(business_id, 'treasury_transfer.view'::text)`; WITH CHECK `—`


## نقاط هندسية لا يجوز نسخها كما هي

1. `purchase_returns` و`purchase_return_items` يستخدمان FKs منفصلة إلى الفاتورة/المورد/المنتج/بند الشراء/المرتجع، ولا تفرض هذه الروابط في Test أن كل السجلات تابعة إلى `business_id` نفسه.
2. `customer_credit_ledger` يربط العميل والفاتورة والدفعة والمرتجع عبر UUIDs منفصلة؛ يحتاج same-business composite FKs بعد إنشاء UNIQUE(business_id,id) على الجداول المرجعية.
3. `purchase_invoice_cost_snapshots` و`stock_adjustment_cost_snapshots` يحتاجان composite FKs على `(business_id,invoice_id)` و`(business_id,movement_id)` بعد تجهيز المفاتيح المرجعية.
4. `operation_counters` مفتاحه الأساسي `(business_id,operation_type))، وعليه RLS بلا سياسات ولا grants لأدوار API؛ لا تضف له SELECT/INSERT/UPDATE مباشرة.
5. `treasury_transfers` يملك بالفعل FK مركبًا للعكس يضمن أن التحويل الأصلي من نفس النشاط، وفهرس unique يمنع عكس التحويل أكثر من مرة. حافظ على ذلك.
6. يجب فحص قيود الصيغ والأكواد والـpartial unique indexes بعناية؛ لا تكتفِ بإنشاء الجداول والأعمدة.

## طريقة استخدام هذا المرجع

- اعتبر الأعمدة والقيود والفهارس والسياسات أعلاه baseline من Test.
- قارنها مع تعريفات Production الحالية قبل كل DDL.
- افحص كل بيانات Production قبل إضافة قيد جديد.
- أضف المفاتيح المركبة وFKs same-business في الحزمة الجديدة، بعد فحص التكرار والصفوف orphan.
- لا تنقل بيانات أو counters من Test.
- لا تشغل هذا الملف؛ هو توثيق فقط، وليس SQL.


## تدقيق إضافي — الدقة العددية وتصميم علاقات same-business (25 نوفمبر 2026)

تم استخراج الدقة الفعلية من `information_schema.columns` في Test؛ القيم التالية هي المرجع بدل عبارة "precision defined in source" أعلاه:

| الجدول | العمود | النوع الدقيق |
|---|---|---|
| customer_credit_ledger | amount | numeric(14,2) |
| purchase_invoice_cost_snapshots | average_cost_before | numeric(14,2) |
| purchase_return_items | quantity | numeric(14,3) |
| purchase_return_items | unit_cost, line_total | numeric(14,2) |
| purchase_returns | total, credit_generated_total, invoice_due_reduced_total | numeric(14,2) |
| stock_adjustment_cost_snapshots | average_cost_before | numeric(14,2) |
| treasury_transfers | amount | numeric(14,2) |

### علاقات مركبة مطلوبة عند بناء الجداول الجديدة

لا تنسخ FKs أحادية العمود من Test كما هي. يجب أن تستخدم علاقات مركبة تشمل `business_id` حيثما ينتمي الطرفان إلى نشاط:

- `purchase_returns(business_id,purchase_invoice_id)` → `purchase_invoices(business_id,id)`.
- `purchase_returns(business_id,supplier_id)` → `parties(business_id,id)`.
- `purchase_return_items(business_id,return_id)` → `purchase_returns(business_id,id)`.
- `purchase_return_items(business_id,purchase_item_id)` → `purchase_items(business_id,id)`.
- `purchase_return_items(business_id,product_id)` → `products(business_id,id)`.
- `customer_credit_ledger(business_id,customer_id)` → `parties(business_id,id)`.
- `customer_credit_ledger(business_id,source_return_id)` → `sales_returns(business_id,id)`.
- `customer_credit_ledger(business_id,invoice_id)` → `sales_invoices(business_id,id)`.
- `customer_credit_ledger(business_id,payment_id)` → `payments(business_id,id)`.
- `customer_credit_ledger(business_id,reversal_of_id)` → `customer_credit_ledger(business_id,id)`.
- `purchase_invoice_cost_snapshots(business_id,invoice_id)` → `purchase_invoices(business_id,id)`، وكذلك المنتج.
- `stock_adjustment_cost_snapshots(business_id,movement_id)` → `stock_movements(business_id,id))، وكذلك المنتج.
- `treasury_transfers(business_id,reversal_of_transfer_id)` → `treasury_transfers(business_id,id)`.

### مفاتيح مركبة مرجعية ينبغي تجهيزها

المفاتيح المركبة الموجودة حاليًا في Production على الجداول المشتركة تشمل parties وproducts وpurchase_invoices وsales_invoices وsales_items وsales_returns. أما الجداول المرجعية التي ستحتاج UNIQUE(business_id,id) قبل ربطها مركبًا فتشمل — بحسب العلاقات النهائية التي ستُعتمد — payments وstock_movements وcash_transactions، إضافةً إلى الجداول الجديدة ذات المعرفات المستقلة.

لا تضف قيدًا مركبًا على جدول لم يُنشأ بعد، ولا تضف UNIQUE مكررًا إذا كان هناك مفتاح مكافئ. افحص الاسم والتعريف قبل كل DDL.

### نتائج فحص بيانات Production الحالية

تم تنفيذ فحص قراءة فقط لعشر علاقات same-business موجودة بالفعل في بيانات Production:
- purchase_items → purchase_invoices / products
- sales_items → sales_invoices / products
- sales_returns → sales_invoices
- sales_return_items → sales_returns / sales_items / products
- payments → parties
- cash_transactions → parties

النتيجة: **صفر صفوف orphan في العلاقات العشر** وقت الفحص. هذه نتيجة للفحوص المذكورة فقط، ولا تُعد اختبارًا للجداول الجديدة أو العلاقات التي ستُضاف لاحقًا.

لم يتم تنفيذ أي DDL أو DML على Production.


### استكمال علاقات الأعمدة الجديدة في الجداول المشتركة

أظهر استخراج جميع FKs من Test أن هناك روابط إضافية لا يجوز تركها كـUUID references أحادية النشاط عند ترقية Production. يجب أن تشمل الحزمة المقترحة كذلك:

- `payments(business_id,sales_return_id)` → `sales_returns(business_id,id)`.
- `payments(business_id,purchase_return_id)` → `purchase_returns(business_id,id)`.
- `payments(business_id,reversal_of_payment_id)` → `payments(business_id,id)`.
- `cash_transactions(business_id,sales_return_id)` → `sales_returns(business_id,id)`.
- `cash_transactions(business_id,purchase_return_id)` → `purchase_returns(business_id,id)`.
- `cash_transactions(business_id,payment_id)` → `payments(business_id,id)`.
- `cash_transactions(business_id,treasury_transfer_id)` → `treasury_transfers(business_id,id)`.
- `cash_transactions(business_id,reversal_of_transaction_id)` → `cash_transactions(business_id,id)`.
- `expenses(business_id,cash_transaction_id)` → `cash_transactions(business_id,id)`.
- `stock_movements(business_id,reversal_of_movement_id)` → `stock_movements(business_id,id)`.

وبالتالي يلزم تجهيز مفاتيح مرجعية مركبة `UNIQUE(business_id,id)` على payments وcash_transactions وstock_movements، والتحقق من وجودها على treasury_transfers والجداول الأخرى. عند بناء القيود، تُراجع FKs الأحادية المكافئة وتُستبدل بقيود مركبة بدل إبقائها كمسار يسمح بالربط عبر نشاط آخر. لا تنفذ هذا التغيير قبل فحص تعريفات كل قيد وسياسة الحذف والـRPC التي تعتمد عليه.
