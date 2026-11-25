# خريطة اعتماديات RPC الحالية لنسخة Preview

تاريخ الفحص: 25 نوفمبر 2026  
المرجع: `preview/index.html` على development، وقاعدة Test الحالية.

## النتيجة العامة

- الواجهة تستدعي 37 اسم RPC مختلفًا عبر 41 موضع استدعاء.
- يوجد 39 توقيعًا فعليًا في Test بسبب overloads.
- كل التوقيعات الـ39 المفحوصة `SECURITY DEFINER` مع `search_path=""`.
- كل توقيع يسمح بـEXECUTE لـ`authenticated` ويرفض `anon` و`PUBLIC`.
- الخريطة أدناه مستخرجة ساكنًا من أجسام الدوال؛ تذكر الجداول المشار إليها نصيًا وأسماء helpers المعروفة. لا تعتبر اختبارًا لسلوك الدالة.

## جدول الاعتماديات

| التوقيع | الجداول التي تشير إليها الدالة | Helpers معروفة |
|---|---|---|
| `add_business_member_by_email(uuid,text,text)` | `business_members` | — |
| `create_treasury_transfer(uuid,text,text,numeric,date,text)` | `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `get_treasury_balances(uuid)` | `payments`, `cash_transactions`, `treasury_transfers` | `has_business_permission` |
| `list_business_members(uuid)` | `business_members` | — |
| `owner_remove_cash_opening_balance(uuid)` | `business_members`, `cash_transactions`, `audit_log` | — |
| `owner_remove_cash_transaction(uuid,uuid)` | `business_members`, `payments`, `expenses`, `cash_transactions`, `audit_log`, `treasury_transfers` | — |
| `owner_remove_expense(uuid,uuid)` | `business_members`, `payments`, `expenses`, `cash_transactions`, `audit_log`, `treasury_transfers` | — |
| `owner_remove_party(uuid,uuid)` | `business_members`, `parties`, `purchase_invoices`, `sales_invoices`, `payments`, `sales_returns`, `cash_transactions`, `audit_log` | — |
| `owner_remove_party_opening_balance(uuid,uuid)` | `business_members`, `parties`, `purchase_invoices`, `sales_invoices`, `payments`, `sales_returns`, `cash_transactions`, `audit_log` | — |
| `owner_remove_product(uuid,uuid)` | `business_members`, `products`, `purchase_items`, `sales_items`, `stock_movements`, `sales_return_items`, `audit_log` | — |
| `owner_remove_sales_return(uuid,uuid)` | `business_members`, `products`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `sales_return_items`, `cash_transactions`, `audit_log`, `customer_credit_ledger` | — |
| `owner_restore_party(uuid,uuid)` | `business_members`, `parties`, `audit_log` | — |
| `owner_restore_product(uuid,uuid)` | `business_members`, `products`, `audit_log` | — |
| `owner_reverse_customer_invoice_payment(uuid,uuid)` | `business_members`, `sales_invoices`, `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | — |
| `owner_reverse_invoice_payment(uuid,uuid)` | `business_members`, `purchase_invoices`, `payments`, `cash_transactions`, `audit_log` | — |
| `owner_reverse_standalone_party_payment(uuid,uuid)` | `business_members`, `payments`, `cash_transactions`, `audit_log`, `treasury_transfers`, `customer_credit_ledger` | — |
| `owner_void_invoice(uuid,text,uuid)` | `business_members`, `products`, `purchase_invoices`, `purchase_items`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `cash_transactions`, `audit_log`, `purchase_invoice_cost_snapshots`, `treasury_transfers`, `customer_credit_ledger` | — |
| `owner_void_purchase_return(uuid,uuid)` | `business_members`, `products`, `purchase_invoices`, `payments`, `stock_movements`, `cash_transactions`, `audit_log`, `treasury_transfers`, `purchase_returns`, `purchase_return_items` | `has_business_permission` |
| `pay_customer_credit(uuid,uuid,numeric,date,text,text,text)` | `parties`, `payments`, `cash_transactions`, `audit_log`, `treasury_transfers`, `customer_credit_ledger` | `has_business_permission` |
| `post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)` | `products`, `purchase_invoices`, `purchase_items`, `payments`, `stock_movements`, `cash_transactions`, `audit_log`, `purchase_returns`, `purchase_return_items` | `has_business_permission`, `next_operation_code` |
| `post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)` | `products`, `parties`, `purchase_invoices`, `purchase_items`, `payments`, `stock_movements`, `cash_transactions`, `audit_log`, `purchase_invoice_cost_snapshots`, `treasury_transfers` | `has_business_permission`, `next_operation_code` |
| `post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)` | `businesses`, `products`, `parties`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `cash_transactions`, `audit_log`, `customer_credit_ledger` | `has_business_permission`, `next_operation_code` |
| `post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)` |  | — |
| `post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)` | `products`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `sales_return_items`, `cash_transactions`, `audit_log`, `treasury_transfers`, `customer_credit_ledger` | `has_business_permission`, `next_operation_code` |
| `post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)` | `products`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `sales_return_items`, `cash_transactions`, `audit_log` | `has_business_permission`, `next_operation_code` |
| `post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)` | `products`, `stock_movements`, `audit_log`, `stock_adjustment_cost_snapshots` | `has_business_permission` |
| `post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)` | `products`, `stock_movements`, `audit_log` | `has_business_permission` |
| `receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)` | `parties`, `payments`, `cash_transactions`, `audit_log` | `has_business_permission` |
| `record_cash_opening_balance(uuid,numeric,date,text)` | `cash_transactions`, `audit_log` | `has_business_permission` |
| `record_expense(uuid,text,numeric,date,text,text)` | `payments`, `expenses`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)` | `purchase_invoices`, `sales_invoices`, `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)` | `parties`, `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `record_treasury_deposit(uuid,text,numeric,text,date,text)` | `cash_transactions`, `audit_log` | `has_business_permission` |
| `record_treasury_withdrawal(uuid,text,numeric,text,date,text)` | `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `reset_business_data(uuid)` | `business_members`, `products`, `parties`, `purchase_invoices`, `purchase_items`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `sales_return_items`, `expenses`, `cash_transactions`, `business_settings`, `audit_log`, `purchase_invoice_cost_snapshots`, `stock_adjustment_cost_snapshots`, `treasury_transfers`, `purchase_returns`, `purchase_return_items`, `customer_credit_ledger` | — |
| `restore_business_backup(uuid,jsonb)` | `businesses`, `business_members`, `products`, `parties`, `purchase_invoices`, `purchase_items`, `sales_invoices`, `sales_items`, `payments`, `stock_movements`, `sales_returns`, `sales_return_items`, `expenses`, `cash_transactions`, `business_settings`, `audit_log`, `purchase_invoice_cost_snapshots`, `stock_adjustment_cost_snapshots`, `treasury_transfers`, `purchase_returns`, `purchase_return_items`, `customer_credit_ledger` | — |
| `reverse_treasury_transfer(uuid,uuid)` | `payments`, `cash_transactions`, `audit_log`, `treasury_transfers` | `has_business_permission` |
| `set_party_opening_balance(uuid,uuid,numeric,text)` | `parties`, `purchase_invoices`, `sales_invoices`, `payments`, `sales_returns`, `audit_log` | `has_business_permission` |
| `update_business_member(uuid,uuid,text,boolean,jsonb)` | `business_members`, `products`, `parties`, `payments`, `expenses` | — |

## ترتيب بناء الحزمة المقترح من الاعتماديات

1. **الجذر والعضويات والصلاحيات:** `businesses`, `business_members`, `has_business_permission`, `has_business_role`, `update_business_member`, `add_business_member_by_email`, `list_business_members`.
2. **الكتالوج والأطراف:** `products`, `parties`، ثم صلاحيات الكتابة المباشرة والأعمدة المحمية.
3. **عدادات الترقيم والتدقيق:** `operation_counters`, `next_operation_code`, triggers الأكواد، `audit_log`.
4. **دفاتر الشراء والمخزون:** `purchase_invoices`, `purchase_items`, `purchase_invoice_cost_snapshots`, `stock_movements`, `stock_adjustment_cost_snapshots`.
5. **دفاتر البيع والمرتجعات:** `sales_invoices`, `sales_items`, `sales_returns`, `sales_return_items`, `customer_credit_ledger`.
6. **دفتر الخزنة ووسائل الدفع:** `payments`, `cash_transactions`, `treasury_transfers`, `expenses`.
7. **Views:** أرصدة الخزنة، المخزون، حسابات الأطراف، كشف الحساب، أرصدة العميل الدائنة.
8. **RPCs التشغيلية:** تسجيل العمليات، ثم العكس والإلغاء، ثم الاستعادة/التصفير بعد تدقيق خاص.
9. **RLS/ACL/Storage:** تثبيت صلاحيات القراءة والكتابة بعد اكتمال الاعتماديات، ثم فحص كامل.

## نقاط حساسة

- `reset_business_data` و`restore_business_backup` لا يُنفذان ضمن اختبارات معاملات تلقائية على Production. يجب مراجعة سلوكهما منفصلًا، وخصوصًا restore لأنه يستخدم dynamic SQL/JSON row population ويغطي جداول أكثر من النسخة القديمة.
- عمليات عكس الدفعات والمرتجعات تعتمد على روابط reversal ولقطات التكلفة قبل الحركة؛ لذلك يجب إضافة الأعمدة والقيود قبل نشر هذه RPCs.
- `post_purchase_return_with_settlement` و`owner_void_purchase_return` يعتمدان على `purchase_returns` و`purchase_return_items` ودفتر المورد والدفعات والخزنة.
- `pay_customer_credit` و`owner_reverse_standalone_party_payment` يعتمدان على `customer_credit_ledger`.
- `create_treasury_transfer` و`reverse_treasury_transfer` يعتمدان على `treasury_transfers` ودفتر الخزنة، ويجب اختبار رصيد المصدر قبل/بعد التحويل والعكس.

## حدود الاستخراج

- التحليل يعتمد على أسماء الجداول الظاهرة في نصوص الدوال؛ لا يستخرج كل أعمدة SQL أو كل علاقات التنفيذ الديناميكية.
- لا يشمل الدوال الداخلية التي لا تستدعيها الواجهة مباشرة إلا بقدر ظهورها كـhelper.
- يلزم فحص ACL/ownership/definition لكل توقيع ضمن الحزمة النهائية.
- لم يتم تنفيذ أي تعديل على قاعدة البيانات.


## مراجعة تفاعل RPC مع قيود same-business — 25 نوفمبر 2026

تمت قراءة تعريفات الدوال الفعلية في Test (وليس أسماء الجداول فقط) للدوال التي تنشئ أو تعكس دفعات/حركات خزنة/مخزون/مصروفات/تحويلات. النتائج:

### الدوال التي تُدخل business_id صراحةً في السجلات

- `record_invoice_payment`, `record_standalone_party_payment`, `record_expense`.
- `post_purchase_with_method`, `post_sale_with_method` (التوقيع الحديث ذو 10 وسائط).
- `post_purchase_return_with_settlement`, `post_sales_return` (كلا overloads).
- `post_stock_adjustment`, `post_stock_condition_transfer`.
- `create_treasury_transfer`, `reverse_treasury_transfer`.
- دوال العكس: `owner_reverse_invoice_payment`, `owner_reverse_customer_invoice_payment`, `owner_reverse_standalone_party_payment`, `owner_void_invoice`, `owner_void_purchase_return`.

في التعريفات التي تمت مراجعتها، عمليات INSERT ذات الصلة تكتب `business_id` من وسيط النشاط نفسه، وتصفية سجلات العكس/التحديث تستخدم `business_id` مع المعرفات. هذا مؤشر توافق ساكن مع القيود المركبة المقترحة، وليس إثباتًا عمليًا أن كل مسارات التنفيذ ستنجح.

### المفاتيح المرجعية المركبة التي لا تظهر في Test حاليًا

استعلام قيود PK/UNIQUE كشف أن الجداول التالية لا تملك حتى الآن `UNIQUE(business_id,id)` رغم أنها أهداف لعلاقات same-business المقترحة:

- `payments`
- `cash_transactions`
- `stock_movements`
- `expenses` (مطلوب فقط إذا أضيفت علاقة مركبة تشير إليها؛ لا تضفها بلا حاجة)

المفاتيح المركبة موجودة بالفعل في Test على `customer_credit_ledger`, `purchase_returns`, `treasury_transfers`. لا نكررها.

ملاحظة: `stock_adjustment_cost_snapshots` مفتاحه الأساسي `(business_id,movement_id)`، لذلك لا يحتاج مفتاحًا مكررًا على الزوج نفسه. أما `purchase_invoice_cost_snapshots` فمفتاحه الأساسي `(invoice_id,product_id)` ولا يُفترض أن يكون هدفًا لروابط تشغيلية قبل تصميم مستقل.

### أثر مهم على ترتيب الحزمة

1. إنشاء الجداول الجديدة مع المفاتيح الأساسية والفهارس وRLS.
2. إضافة `UNIQUE(business_id,id)` إلى payments/cash_transactions/stock_movements، بعد فحص تكرارات الزوج (ينبغي أن تكون مستحيلة مع id PK لكن نفحصها قبل DDL).
3. إضافة FKs المركبة للجداول الجديدة وروابط reversal/cash settlement على الجداول المشتركة.
4. مراجعة/إزالة FKs الأحادية المكافئة بعد التحقق من أن كل FK مركب يغطي نفس ON DELETE behavior، مع الحفاظ على روابط auth.users وروابط business_id المنفصلة.
5. بعدها فقط تثبيت الدوال والـtriggers والـviews والـACLs، ثم اختبار المعاملات على Test.

### مخاطر تحتاج اختبارًا وظيفيًا على Test

- `record_expense` ينشئ expense ثم cash_transaction ثم يحدّث expense بـ`cash_transaction_id`; أي FK مركب هنا يجب أن يكون متوافقًا مع نفس business_id على طرفي السجل.
- عكس الدفعات يضيف payment عكسيًا ثم cash_transaction عكسيًا ويربط السجل الأصلي؛ يجب اختبار uniqueness ومنع العكس المكرر.
- مرتجع المشتريات ينشئ stock movement/payment/cash transaction متصلة بالمرتجع؛ يجب اختبار business_id الموحد وسياسة الحذف.
- `owner_void_invoice` و`owner_void_purchase_return` يضيفان حركات عكسية متعددة، ويجب اختبار عدم كسر القيود مع السجلات التاريخية.
- يوجد overload قديم لـ`post_sale_with_method` بتسع وسائط، جسمه قصير (wrapper)، بجانب التوقيع الحديث ذي عشر وسائط. يجب الحفاظ على السلوك/التوجيه وعدم إسقاطه أثناء بناء الحزمة.

لم يتم تعديل أي RPC أو تنفيذ أي SQL DDL/DML في هذه المراجعة.
