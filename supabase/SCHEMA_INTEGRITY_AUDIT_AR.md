# تدقيق سلامة العلاقات بين الأنشطة (Composite Foreign Keys)

آخر تحديث: 25 نوفمبر 2026  
البيئة المفحوصة: Test `hxwcjbmlxbqrurrmjbpf`  
نوع الفحص: قراءة تعريفات القيود فقط، دون أي DDL/DML.

## النتيجة

قاعدة Test هي المرجع الوظيفي الأحدث، لكنها ليست مثالية كقالب نسخ مباشر. توجد علاقات بين جداول تشغيلية تعتمد على UUID وحده، رغم أن كل سجل يحمل `business_id`. هذا يسمح نظريًا بربط سجل من نشاط بسجل تابع لنشاط آخر إذا وصلت عملية إدراج إلى قاعدة البيانات دون حارس مناسب. يجب معالجة ذلك في حزمة Production additive بدل نسخ القيود الضعيفة كما هي.

## مفاتيح مركبة موجودة في Test

| الجدول | المفتاح المركب |
|---|---|
| `parties` | `UNIQUE (business_id, id)` |
| `products` | `UNIQUE (business_id, id)` |
| `purchase_invoices` | `UNIQUE (business_id, id)` |
| `sales_invoices` | `UNIQUE (business_id, id)` |
| `sales_returns` | `UNIQUE (business_id, id)` |
| `purchase_returns` | `UNIQUE (business_id, id)` |
| `treasury_transfers` | `UNIQUE (business_id, id)` |
| `customer_credit_ledger` | `UNIQUE (business_id, id)` |

جداول مهمة لا تملك المفتاح المركب المطلوب حاليًا:
- `purchase_items`
- `payments`
- `cash_transactions`
- `stock_movements`
- `purchase_return_items`

## علاقات يلزم تقويتها قبل الترقية

### مرتجعات المشتريات
- `purchase_returns(business_id, purchase_invoice_id)` يجب أن تشير إلى `purchase_invoices(business_id, id)`.
- `purchase_returns(business_id, supplier_id)` يجب أن تشير إلى `parties(business_id, id)`.
- `purchase_return_items(business_id, return_id)` يجب أن تشير إلى `purchase_returns(business_id, id)`.
- `purchase_return_items(business_id, product_id)` يجب أن تشير إلى `products(business_id, id)`.
- `purchase_return_items(business_id, purchase_item_id)` تحتاج أولًا مفتاحًا فريدًا `purchase_items(business_id, id)`، ثم FK مركبًا.

### دفتر رصيد العميل
القيود الحالية في Test على `customer_credit_ledger` تستخدم UUID منفردًا للعميل والفاتورة والدفعة والمرتجع وسجل العكس. يلزم تصميم علاقات مركبة:
- customer → `parties(business_id,id)`
- invoice → `sales_invoices(business_id,id)`
- source return → `sales_returns(business_id,id)`
- payment → إضافة `UNIQUE (business_id,id)` إلى `payments` ثم FK مركب
- reversal → FK ذاتي على `(business_id,reversal_of_id)` إلى `customer_credit_ledger(business_id,id)`

يجب الحفاظ على `UNIQUE(reversal_of_id)` أو تحويله إلى قيد فريد مركب مناسب مع التأكد من منع العكس المكرر عبر الأنشطة.

### روابط الدفعات والخزنة
- `payments` لديه بالفعل FKs مركبة للعميل/المورد ومرتجع البيع ومرتجع الشراء، لكن `reversal_of_payment_id` ما زال UUID فقط. يحتاج `UNIQUE(payments.business_id,id)` وFK مركب.
- `cash_transactions` لديه FKs مركبة للطرف ومرتجع البيع ومرتجع الشراء؛ لكن `payment_id`, `treasury_transfer_id`, و`reversal_of_transaction_id` ما زالت UUID فقط. يلزم مفاتيح فريدة مركبة للأبوين وFKs على `(business_id,id)`.
- `treasury_transfers` لديه بالفعل علاقة عكس مركبة داخل النشاط، ومفتاح `UNIQUE(business_id,id)`.

### لقطات التكلفة
- `purchase_invoice_cost_snapshots` يشير إلى فاتورة الشراء والمنتج عبر UUID فقط، رغم وجود `business_id`. يمكن تقويته باستخدام مفاتيح `purchase_invoices` و`products` المركبة.
- `stock_adjustment_cost_snapshots` يشير إلى حركة المخزون والمنتج عبر UUID فقط. المنتجات لديها مفتاح مركب، لكن `stock_movements` يحتاج مفتاحًا فريدًا مركبًا قبل إضافة FK على `(business_id,movement_id)`.

## ملاحظات تنفيذية

1. لا تضف قيودًا مركبة قبل فحص أي صفوف يتيمة أو cross-business في Production؛ حتى لو كانت الجداول التشغيلية التي فُحصت صفرًا، يجب التحقق من جميع الجداول ذات الصلة قبل DDL.
2. لا تزل القيود الأحادية القديمة تلقائيًا. يمكن أن تبقى مؤقتًا بعد إضافة المركبة، ثم يراجع أثرها على الخطط والفهارس.
3. يجب أن تكون القيود الجديدة `NOT VALID` عند الحاجة فقط، ثم `VALIDATE CONSTRAINT` بعد فحص البيانات؛ لا تستخدمها لتجاوز أخطاء البيانات.
4. إنشاء `UNIQUE(business_id,id)` يحتاج فحص التكرار أولًا، ويجب أن يكون في نفس دفعة ترتيب الاعتماديات.
5. لا بد من إضافة فهارس مساعدة مناسبة للـFKs، ومراجعة كلفة الترقية على قاعدة Production.
6. يجب أن تظل كل جداول التشغيل RLS-enabled، مع عدم منح anon/PUBLIC أي وصول مباشر غير ضروري.

## حالة القرار

هذه فجوة تصميم في Test نفسها، لذلك لا يجوز نسخ قيود Test حرفيًا إلى Production. يلزم تضمين تقوية same-business في تصميم Migration الجديدة، ومراجعة كل FK مع مالكه/وظيفته قبل التنفيذ.

لم يتم تنفيذ أي تغيير على Test أو Production.
