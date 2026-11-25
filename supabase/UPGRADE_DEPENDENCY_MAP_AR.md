# خريطة اعتماديات ترقية Production — الإصدار التحليلي

تاريخ: 25 نوفمبر 2026  
المصدر المرجعي للواجهة: `preview/index.html` في `development`، blob `786bdfab945aa605b8f317cb8dcace809bdd8b66`  
Test: `hxwcjbmlxbqrurrmjbpf` — Production: `njvaxrucfwgksqdfbckt`  
النطاق: تحليل قراءة فقط؛ لا توجد أوامر DDL/DML في هذا الملف.

## 1. الفروق المؤكدة بين Test وProduction

| المكوّن | Test | Production | المطلوب |
|---|---:|---:|---|
| الجداول الأساسية | 26 | 16 | 7 تشغيلية جديدة + عدم نقل 3 جداول backup |
| Views | 7 | 5 | إنشاء 2، وتحديث 5 |
| أعمدة الجداول | أحدث | أقدم | إضافة 32 عمودًا |
| Triggers غير الداخلية | 17 | 9 | إضافة 8 |
| سياسات RLS | 35 | 29 | إضافة 6 وتحديث payments_read |
| توقيعات RPC المطلوبة من Preview | 39 | 10 | 9 متطابقة تمامًا فقط؛ 30 توقيعًا غير متاح |
| Storage bucket | متطابق | متطابق | لا تغيير |

ملاحظة العدّ: Preview يستدعي 37 اسم RPC فريدًا. يظهر في Test توقيعان overload إضافيان، لذلك عدد التوقيعات 39. في Production توجد 10 توقيعات تحت الأسماء المطلوبة، لكن `record_expense` توقيعه قديم ولا يطابق الواجهة. توجد 9 توقيعات مطابقة تمامًا، و30 توقيعًا من Test غير موجودة بالتوقيع نفسه في Production.

## 2. الجداول التشغيلية السبعة التي يجب إنشاؤها

1. `purchase_invoice_cost_snapshots`
2. `stock_adjustment_cost_snapshots`
3. `operation_counters`
4. `treasury_transfers`
5. `purchase_returns`
6. `purchase_return_items`
7. `customer_credit_ledger`

لا تنقل صفوف Test. تُنشأ البنية فارغة في Production، وتُهيأ العدادات فقط من الأكواد الموجودة في Production بعد فحص الصيغة والتكرارات.

لا تنشئ جداول النسخ الاختبارية:
- `_pre_reset_backup_20261118`
- `test_reset_backup_20261118`
- `test_full_backup_20261120`

## 3. الأعمدة الـ32 الناقصة في Production

| الجدول | الأعمدة |
|---|---|
| `businesses` | `tagline` |
| `cash_transactions` | `reversal_of_transaction_id`, `sales_return_id`, `payment_id`, `treasury_transfer_id`, `transaction_code`, `account_method`, `purchase_return_id` |
| `expenses` | `cash_transaction_id`, `status`, `voided_at`, `voided_by`, `expense_code` |
| `parties` | `is_active`, `party_code` |
| `payments` | `sales_return_id`, `reversal_of_payment_id`, `posted_at`, `party_account_type`, `payment_code`, `purchase_return_id` |
| `purchase_invoices` | `supplier_credit_applied_total` |
| `sales_invoices` | `customer_credit_applied_total` |
| `sales_return_items` | `unit_price` |
| `sales_returns` | `status`, `posted_at`, `invoice_due_reduced_total` |
| `stock_movements` | `reversal_of_movement_id`, `posted_at`, `movement_code`, `stock_bucket`, `average_cost_before` |

كل عمود يحتاج نوعًا وdefault وcheck وindex/FK مناسبًا، وليس مجرد `ADD COLUMN` عشوائيًا. يجب تحديد backfill للصفوف القائمة قبل فرض NOT NULL. جداول Production الحالية ذات بيانات قليلة، لكن لا نفترض إمكان إسقاط أي صف.

## 4. الـViews

### إنشاء
- `customer_credit_balances`
- `customer_credit_return_balances`

### تحديث تعريفات موجودة
- `cash_balances`: قصر الرصيد النقدي على `account_method='cash'`.
- `daily_business_summary`: تضمين وسائل الدفع/المرتجعات/الحركات الحديثة وفق تعريف Test.
- `party_account_balances`: إدراج `purchase_returns_total` و`customer_net_collected) وحساب صافي المورد والعميل.
- `party_account_statement`: تضمين `entry_timestamp)، الدفعات المستقلة والعكس، مرتجعات الشراء، واستبعاد المرتجعات الملغاة.
- `product_stock_balances`: فصل الصالح والتالف وإرجاع `damaged_quantity`, `total_stock_quantity`, `has_stock_history`, `out_of_stock`.

جميع Views المفحوصة في Test وProduction تحمل `security_invoker=true`. يجب الحفاظ على ذلك. توجد صلاحية SELECT على بعض Views لـanon؛ وبما أن `security_invoker` يطبق صلاحيات الجداول الأساسية وسياساتها، لا نعتبر هذا وحده إثباتًا لتسريب. مع ذلك، يجب مراجعة grants على Views والـbase tables وتقليل وصول anon غير المطلوب ضمن الحزمة.

## 5. Triggers الثمانية الناقصة

- `cash_transactions_assign_code`
- `expenses_assign_code`
- `parties_assign_code`
- `payments_assign_code`
- `trg_auto_purchase_invoice_number`
- `trg_auto_sales_invoice_number`
- `stock_movements_assign_code`
- `treasury_transfers_assign_code`

تعتمد على `assign_business_record_code`, `next_operation_code`, و`assign_automatic_invoice_number`. قبل إضافة التريجرات يجب التأكد من تعريفات الدوال، صلاحيات EXECUTE، search_path، صيغة الأكواد الحالية، والتأكد أن أول رقم جديد يتجاوز أعلى لاحقة مستخدمة وليس count(*) فقط.

## 6. سياسات RLS الست الناقصة وتغيير سياسة

| الجدول | السياسة |
|---|---|
| `customer_credit_ledger` | SELECT وفق `sales.view` أو `parties.view` |
| `purchase_invoice_cost_snapshots` | SELECT للمالك فقط |
| `purchase_return_items` | SELECT وفق `purchases.view` |
| `purchase_returns` | SELECT وفق `purchases.view` |
| `stock_adjustment_cost_snapshots` | SELECT للمالك فقط |
| `treasury_transfers` | SELECT وفق `treasury_transfer.view` |

سياسة `payments_read` في Test تسمح للموظف بقراءة الدفعة المستقلة إذا كان لديه `payments.view` ومعها صلاحية عرض حساب العميل أو المورد. Production تقصر الدفعات المستقلة التي لا ترتبط بفاتورة على owner/admin. لا يمكن تحديث السياسة قبل إضافة `party_account_type` ومراجعة صلاحيات الموظفين. لا تنقل GRANT SELECT لـanon على purchase returns/items أو treasury transfers من Test؛ هذه منح زائدة.

## 7. ترتيب بناء الحزمة

1. حفظ خط الأساس وفحص سلامة النشاط والعضوية والبيانات والأكواد في Production.
2. إضافة أعمدة nullable/مع defaults مناسبة، ثم backfill محدود ومثبت.
3. إنشاء مفاتيح أم مركبة `UNIQUE(business_id,id)` المطلوبة بعد فحص التكرار.
4. إنشاء الجداول السبعة وقيودها وIndexes وRLS، مع FKs مركبة same-business؛ لا تنسخ القيود الأحادية الضعيفة في Test.
5. إضافة/تحديث Views مع `security_invoker=true` ومراجعة grants.
6. إنشاء helper functions وcode triggers، بعد تصحيح تهيئة العدادات من أعلى لاحقة فعلية.
7. إنشاء RPCs في مجموعات صغيرة وفق اعتمادياتها: الأطراف/المنتجات، المشتريات، المبيعات، الخزنة، الدفعات والعكس، المرتجعات والرصيد الدائن.
8. إنشاء سياسات RLS النهائية وتحديث `payments_read` بعد الأعمدة.
9. إضافة Triggers النهائية وفحص ترتيب الأقفال.
10. Advisors وACL/SECURITY DEFINER/search_path ومقارنة تعريفات كل RPC/Views/Triggers.
11. اختبار غير مالي ببيانات اختبار اصطناعية على Test فقط؛ لا توجد بيئة clone مجانية مؤكدة، لذلك لا ندعي أن Production تم اختبارها كنسخة مطابقة.
12. بعد موافقة مستقلة على ترقية Production: أخذ backup مناسب، تنفيذ الحزمة additive، فحوص postconditions، ثم تجهيز الواجهة والتحويل مع rollback.

## 8. بوابات لا يمكن تجاوزها

- **سياسة متوسط التكلفة:** الشراء يحسب على إجمالي الكمية، والتسوية على الصالح فقط. لا بد من اعتماد قاعدة واحدة قبل تغيير الدوال.
- **مصادر 055/056:** نصوص SQL الأصلية غير موجودة. لا نخترعها؛ نعيد بناء تغييرات additive من تعريفات Test بعد مراجعتها.
- **مرتجعات المشتريات متعددة الفواتير:** الواجهة الحالية لا تدعمها؛ تتطلب source allocation على مستوى المبيعات والمخزون. هذه ميزة غير منفذة، ولا يتم إدخالها ضمن نقل النسخة الحالية دون قرار مستقل.
- **نشر الواجهة:** يجب الحفاظ على Edge Function `app-preview` وتحديد هل التحويل النهائي سيكون عبرها أو GitHub Pages.
- **الاختبارات:** لا توجد قاعدة Clone مجانية مؤكدة. لا نختبر على Production بعمليات مالية فعلية.
- **التكلفة:** لا إنشاء مشاريع أو Branches أو خدمات مدفوعة؛ كل العمل الحالي يعتمد على المشروعين الحاليين.

## 9. حالة التنفيذ

- اكتملت المقارنة البنيوية/الساكنة.
- لم تُنشأ Migration تنفيذية لProduction.
- لم يتغير أي شيء في Production أو main أو Edge Function.
- لا تعتبر هذه الوثيقة موافقة لتطبيق الحزمة.


## ملحق: نتائج المطابقة التفصيلية للـRPC

تم إنشاء `RPC_COMPATIBILITY_MATRIX_AR.md` بعد إعادة استخراج كل استدعاءات Preview من blob الحالي:
- 37 اسم RPC فريدًا.
- 39 توقيعًا في Test.
- 10 توقيعات تحت الأسماء المطلوبة في Production.
- 9 توقيعات مطابقة حرفيًا.
- 30 توقيعًا مطلوبًا غير متاح في Production بالتوقيع نفسه.
- `record_expense` موجود بالاسم لكنه لا يقبل `p_method`؛ لذلك لا يُعد متوافقًا.
