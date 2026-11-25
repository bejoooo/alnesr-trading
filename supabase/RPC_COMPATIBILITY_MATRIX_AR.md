# مصفوفة توافق RPC بين Preview وTest وProduction

تاريخ الفحص: 25 نوفمبر 2026  
Preview blob: `786bdfab945aa605b8f317cb8dcace809bdd8b66`  
Test: `hxwcjbmlxbqrurrmjbpf` — Production: `njvaxrucfwgksqdfbckt`

## الملخص

- Preview يستدعي 37 اسم RPC فريدًا.
- Test يحتوي 39 توقيعًا من الأسماء المطلوبة.
- Production يحتوي 10 توقيعًا من الأسماء المطلوبة.
- التوقيعات المطابقة حرفيًا بين Test وProduction: 9.
- التوقيعات الموجودة في Test وغير الموجودة بالتوقيع نفسه في Production: 30.
- لا يعني وجود اسم RPC في Production أن التوقيع أو المنطق متوافق؛ `record_expense` مثال على وجود الاسم مع توقيع أقدم.

## المصفوفة

| RPC | توقيعات Test | توقيعات Production | الحالة |
|---|---|---|---|
| `add_business_member_by_email` | `add_business_member_by_email(uuid,text,text)` | `add_business_member_by_email(uuid,text,text)` | مطابق |
| `create_treasury_transfer` | `create_treasury_transfer(uuid,text,text,numeric,date,text)` | — | مفقود |
| `get_treasury_balances` | `get_treasury_balances(uuid)` | — | مفقود |
| `list_business_members` | `list_business_members(uuid)` | `list_business_members(uuid)` | مطابق |
| `owner_remove_cash_opening_balance` | `owner_remove_cash_opening_balance(uuid)` | — | مفقود |
| `owner_remove_cash_transaction` | `owner_remove_cash_transaction(uuid,uuid)` | — | مفقود |
| `owner_remove_expense` | `owner_remove_expense(uuid,uuid)` | — | مفقود |
| `owner_remove_party` | `owner_remove_party(uuid,uuid)` | — | مفقود |
| `owner_remove_party_opening_balance` | `owner_remove_party_opening_balance(uuid,uuid)` | — | مفقود |
| `owner_remove_product` | `owner_remove_product(uuid,uuid)` | — | مفقود |
| `owner_remove_sales_return` | `owner_remove_sales_return(uuid,uuid)` | — | مفقود |
| `owner_restore_party` | `owner_restore_party(uuid,uuid)` | — | مفقود |
| `owner_restore_product` | `owner_restore_product(uuid,uuid)` | — | مفقود |
| `owner_reverse_customer_invoice_payment` | `owner_reverse_customer_invoice_payment(uuid,uuid)` | — | مفقود |
| `owner_reverse_invoice_payment` | `owner_reverse_invoice_payment(uuid,uuid)` | — | مفقود |
| `owner_reverse_standalone_party_payment` | `owner_reverse_standalone_party_payment(uuid,uuid)` | — | مفقود |
| `owner_void_invoice` | `owner_void_invoice(uuid,text,uuid)` | — | مفقود |
| `owner_void_purchase_return` | `owner_void_purchase_return(uuid,uuid)` | — | مفقود |
| `pay_customer_credit` | `pay_customer_credit(uuid,uuid,numeric,date,text,text,text)` | — | مفقود |
| `post_purchase_return_with_settlement` | `post_purchase_return_with_settlement(uuid,text,uuid,jsonb,date,text,text,boolean)` | — | مفقود |
| `post_purchase_with_method` | `post_purchase_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)` | — | مفقود |
| `post_sale_with_method` | `post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text,boolean)`<br>`post_sale_with_method(uuid,text,uuid,date,jsonb,numeric,numeric,text,text)` | — | مفقود |
| `post_sales_return` | `post_sales_return(uuid,text,uuid,jsonb,numeric,date,text,text)`<br>`post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)` | `post_sales_return(uuid,text,uuid,jsonb,numeric,date,text)` | جزئي |
| `post_stock_adjustment` | `post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)` | `post_stock_adjustment(uuid,uuid,numeric,text,date,numeric)` | مطابق |
| `post_stock_condition_transfer` | `post_stock_condition_transfer(uuid,uuid,numeric,text,text,text,date)` | — | مفقود |
| `receive_supplier_credit` | `receive_supplier_credit(uuid,uuid,numeric,date,text,text,text)` | — | مفقود |
| `record_cash_opening_balance` | `record_cash_opening_balance(uuid,numeric,date,text)` | `record_cash_opening_balance(uuid,numeric,date,text)` | مطابق |
| `record_expense` | `record_expense(uuid,text,numeric,date,text,text)` | `record_expense(uuid,text,numeric,date,text)` | جزئي |
| `record_invoice_payment` | `record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)` | `record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)` | مطابق |
| `record_standalone_party_payment` | `record_standalone_party_payment(uuid,uuid,text,numeric,date,text,text,text)` | — | مفقود |
| `record_treasury_deposit` | `record_treasury_deposit(uuid,text,numeric,text,date,text)` | — | مفقود |
| `record_treasury_withdrawal` | `record_treasury_withdrawal(uuid,text,numeric,text,date,text)` | — | مفقود |
| `reset_business_data` | `reset_business_data(uuid)` | — | مفقود |
| `restore_business_backup` | `restore_business_backup(uuid,jsonb)` | `restore_business_backup(uuid,jsonb)` | مطابق |
| `reverse_treasury_transfer` | `reverse_treasury_transfer(uuid,uuid)` | — | مفقود |
| `set_party_opening_balance` | `set_party_opening_balance(uuid,uuid,numeric,text)` | `set_party_opening_balance(uuid,uuid,numeric,text)` | مطابق |
| `update_business_member` | `update_business_member(uuid,uuid,text,boolean,jsonb)` | `update_business_member(uuid,uuid,text,boolean,jsonb)` | مطابق |

## نقاط مهمة

1. `post_sale_with_method` له overloads في Test لدعم واجهة تتعامل مع الحقل الاختياري.
2. `post_sales_return` له overloadان في Test؛ Production يحتوي التوقيع الأقدم فقط، ولا يملك التوقيع الحديث الذي يمرر طريقة رد المبلغ.
3. `record_expense` موجود في Production لكن التوقيع هناك لا يستقبل `p_method`؛ لا يعتبر متوافقًا.
4. عمليات عكس الدفعات، الدفعات المستقلة، رصيد العميل الدائن، مرتجعات المشتريات، التحويلات بين وسائل الدفع، وعمليات archive/restore الإضافية غير متاحة في Production.
5. كل توقيع مطلوب يجب مراجعته مع اعتمادات الجداول/الأعمدة/Views/RLS/Triggers، وليس نسخ الدالة وحدها.
6. لا تمنح `anon` أو `PUBLIC` EXECUTE. يجب أن تظل ACL النهائية محددة لـ`authenticated` عند الحاجة، مع فحص auth.uid والعضوية والصلاحيات داخل كل SECURITY DEFINER.

## حالة الأمان

في Production، من أصل 20 SECURITY DEFINER في public:
- 17 قابلة للتنفيذ من authenticated.
- صفر قابلة للتنفيذ من anon أو PUBLIC.
- 16 تستخدم `search_path=public` أو `public, pg_temp`، و3 تستخدم `search_path=""`، وواحدة `pg_catalog`.
- يجب مراجعة وتحصين المسارات قبل إنشاء النسخة الحديثة، وعدم تغيير الدوال الداخلية/trigger-only دون سبب.

لم يتم تنفيذ أي SQL أو تغيير ACL.
