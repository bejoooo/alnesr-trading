# تدقيق ملفات التحقق الهيكلي

تاريخ: 25 نوفمبر 2026  
الفرع: `development`

## 1. الملف القديم `verify_setup.sql`

رأس الملف يقول إنه يُشغّل بعد `schema.sql` وMigrations 002 إلى 011. لكنه يتحقق من مجموعة قديمة من الـRPC signatures. تم تشغيله كما هو على Test الحالي، وهو فحص DO/SELECT فقط ولا يحتوي DML/DDL.

**النتيجة الفعلية:** فشل عند التحقق من:
`public.record_expense(uuid,text,numeric,date,text)`

التوقيع الحالي في Test هو:
`public.record_expense(uuid,text,numeric,date,text,text)`

إذًا الملف القديم لا يطابق حتى توقيع الدالة الحالي في Test. لا تعتمد عليه وحده لقبول Preview أو Production، ولا تعدل تعريف الدالة لتوافق فاحصًا قديمًا.

## 2. فاحص Preview الحالي

تم إنشاء `verify_preview_schema.sql`، وهو فحص كتالوجات قراءة فقط، ويغطي:
- 18 جدولًا تستخدمه الواجهة مباشرة.
- 6 Views تقرؤها الواجهة مباشرة.
- 32 عمودًا حديثًا مطلوبًا.
- 39 توقيع RPC بالضبط من Preview/Test.
- 17 Trigger غير داخلي.
- 6 سياسات RLS مخصصة للجداول التشغيلية الحديثة.
- تفعيل RLS على كل الجداول الـ18.
- إعدادات bucket الخاص `product-images` وسياساته الأربع.
- منع الوصول المباشر من anon/authenticated إلى `operation_counters`.
- صلاحيات EXECUTE: authenticated مسموح، anon وPUBLIC ممنوعان لكل RPC.

### نتيجة التشغيل على Test

**اجتاز الفحص**

أُشغّل النص الكامل للفاحص على Test بتاريخ 25 نوفمبر 2026، وكانت النتيجة:

| البند | العدد |
|---|---:|
| الجداول المباشرة | 18 |
| Views | 6 |
| توقيعات RPC | 39 |
| Triggers | 17 |
| سياسات RLS المخصصة | 6 |
| الأعمدة الحديثة | 32 |

لم ينفذ الفاحص أي DDL أو DML أو معاملات تجارية؛ قرأ كتالوجات PostgreSQL فقط.

## 3. حدود الفاحص الجديد

- يثبت وجود البنية والتوقيعات والسياسات المحددة، ولا يثبت صحة منطق كل دالة.
- لا يختبر تسجيل الدخول أو صلاحيات حسابات حقيقية متعددة.
- لا ينفذ فواتير أو دفعات أو مرتجعات أو تحويلات.
- لا يثبت سلوك التزامن أو التراجع أو rollback.
- لا يغني عن اختبارات العمليات المالية على Test ولا عن مراجعة postconditions بعد ترقية Production.

## 4. القرار

- `verify_setup.sql` يبقى مرجعًا تاريخيًا للتأسيس الأول، ولا يُستخدم بوصفه فاحص Preview الحالي.
- `verify_preview_schema.sql` هو الفاحص الهيكلي المرجعي لنسخة Preview الحالية.
- بعد إعداد حزمة Production، يُشغّل الفاحص على Production بعد الترقية المعتمدة، مع فحوص إضافية خاصة ببيانات baseline والعلاقات same-business.


### تقوية فاحص Preview

تم توسيع `verify_preview_schema.sql` ليتحقق أيضًا من:
- أن كل Views الستة تستخدم `security_invoker=true`.
- أن كل توقيع RPC من الـ39 يستخدم `SECURITY DEFINER` و`search_path=""`.
- استمرار EXECUTE لـauthenticated فقط، ورفض anon وPUBLIC.

أُعيد تشغيل النسخة المقوّاة على Test واجتازت الفحص.


## 5. فاحص Views الإنتاج

أُضيف `verify_production_views.sql` للتحقق من:
- وجود Views الأرصدة والتقارير الستة.
- مطابقة أسماء الأعمدة وترتيبها وأنواعها مع عقد Test.
- وجود `security_invoker=true` على كل View.
- عدم منح SELECT لـanon أو PUBLIC على عرضي رصيد العميل الدائن، مع وجود SELECT لـauthenticated وservice_role.

**نتيجة التشغيل على Test: اجتاز.** الفاحص ينفذ قراءة كتالوجات فقط، ولا ينفذ DDL أو DML. لا يثبت صحة حساب الأرصدة ولا يغني عن اختبار وظيفي ببيانات معروفة.


## 6. توافق استعادة النسخ الاحتياطية

أُضيفت مسودة `PRODUCTION_BACKUP_RESTORE_DRAFT.sql` بعد اكتشاف أن النسخ القديمة قد تفتقد أعمدة أصبحت إلزامية:
- `sales_returns.status` و`posted_at`.
- `sales_return_items.unit_price`.
- `stock_movements.stock_bucket`.
- `cash_transactions.account_method`.

المسودة تستخرج سعر بند المرتجع من `sales_items.unit_price` لنفس `sales_item_id` عند غياب السعر في النسخة؛ ولا تسمح بالاستعادة إذا لم يمكن استرداد السعر. كما تضيف القيم الافتراضية المتوافقة مع السلوك القديم لحقل bucket وطريقة الحساب، وتحافظ على القيم الموجودة في نسخ v3.

لم يُنفذ Restore على Test أو Production. يجب أن تشمل خطة التحقق ملف v2 قديمًا وملف v3 حديثًا، وحالات الإصدار المفقود/غير المدعوم، وغياب السعر الأصلي، وفشل FK مع التأكد من rollback الكامل.


## 7. فاحص الدوال المساعدة والـTriggers

- `verify_test_helper_baseline.sql`: فاحص قراءة فقط للحالة الحالية في Test. **اجتاز**، وأكد 8 دوال و8 Triggers وACL مقيد. يتسامح فقط مع استثناءين معروفين في Test قبل مرحلة التوحيد: `guard_product_average_cost` و`assign_automatic_invoice_number` يستخدمان `search_path=public`.
- `verify_production_helpers.sql`: فاحص صارم لما بعد ترقية Production؛ يشترط `search_path=''` لكل الدوال الثماني، ويفحص SECURITY DEFINER وACL. لم يُشغّل على Test الحالي أو Production بعد.


## 8. فاحص أول دفعة RPCs المالية

أُضيف `verify_production_rpc_batch.sql` لفحص 10 توقيعات RPC الخاصة بالخزنة والمدفوعات والمصروفات والأرصدة الافتتاحية، والتحقق من SECURITY DEFINER و`search_path=''` وACL لـauthenticated/service_role ومنع anon وPUBLIC.

**نتيجة التشغيل على Test: اجتاز.** الفاحص يقرأ كتالوج PostgreSQL فقط ولا ينفذ RPCs أو عمليات مالية. لا يثبت صحة العمليات أو أرصدة الخزنة، ويجب إعادة تشغيله على Production بعد الترقية المعتمدة.


## 9. فاحص دفعة الفواتير والمرتجعات والمخزون

أُضيف `verify_production_posting_rpc_batch.sql` لفحص 10 توقيعات RPC، بما فيها overloads القديمة والحديثة، والتحقق من SECURITY DEFINER و`search_path=''` وصلاحيات authenticated/service_role ومنع anon وPUBLIC.

**نتيجة التشغيل على Test: اجتاز.** الفاحص قراءة كتالوجات فقط ولا ينفذ أي عملية مالية. لا يثبت صحة توزيع الخصومات أو أرصدة المخزون أو المرتجعات أو القيود المحاسبية.


## 10. فاحص دفعة صلاحيات المالك

أُضيف `verify_production_owner_rpc_batch.sql` للتحقق من 17 توقيعًا، وSECURITY DEFINER، و`search_path=''`، وفحص auth.uid وbusiness_members، وACL لـauthenticated/service_role مع منع anon وPUBLIC.

**نتيجة التشغيل على Test: اجتاز.** الفاحص قراءة كتالوجات فقط ولا ينفذ حذفًا أو عكسًا أو إلغاءً لأي حركة.
