# مراجعة تركيبية وأمنية لمسودات Production — 25 نوفمبر 2026

الحالة: مراجعة مصدر فقط؛ لم يتم تشغيل أي مسودة DDL/DML على Test أو Production.

## نتائج هذه الجولة

1. **إصلاح خطأ تركيب SQL في Restore:** كان تعريف `restore_business_backup(uuid,jsonb)` ينتهي بـ`$function$` دون الفاصلة المنقوطة اللازمة. أُضيفت `;` وتأكدنا بإعادة قراءة الملف من GitHub.
2. **تدعيم ترقيم الأكواد:** مسودة helpers تحسب أعلى لاحقة كود بعد بادئة التاريخ ذات 6 أرقام عند إنشاء العداد. أُضيف `PRODUCTION_HELPER_FUNCTIONS_HARDENING_PATCH.sql` لإعادة التوفيق بين العداد الحالي وأعلى كود موجود في كل عملية: `greatest(counter,max_suffix)+1`. كما يرفض null business_id وnull operation_type.
3. **إزالة SQL الديناميكي من AUTO invoice numbering:** الـpatch يستبدل `assign_automatic_invoice_number` باستعلامين ثابتين مؤهلين باسم الجدول، ويحافظ على سلوك الرقم التلقائي الرقمي الحالي، ويستخدم `search_path=''` وSECURITY INVOKER.
4. **تقوية helper path:** الـpatch يضبط `guard_product_average_cost` على `search_path=''`.
5. **فاحص بعد الترقية:** أُضيف `verify_production_helper_functions.sql` للتحقق من خصائص الأمان والعدادات و8 Triggers. لا يُشغّل على Test الحالية لأنها تحتوي تعريف المصدر القديم؛ يُشغّل بعد تطبيق مراحل المسودة على قاعدة اختبار معزولة.
6. **مراجعة تركيبية:** أُعيد فحص إغلاق 47 تعريف function في دفعات RPC والـhelpers والـRestore والـReset؛ جميعها تنتهي الآن بفاصلة منقوطة صحيحة.
7. **Restore dynamic SQL:** بقي استخدام `EXECUTE format` في Restore فقط، داخل حلقة أسماء جداول ثابتة في `required_tables`، مع استخدام `%I` لاقتباس identifier. يجب أن يظل مصدر اسم الجدول من القائمة الثابتة لا من JSON backup.
8. **Supabase Security Advisor على Test:** أظهر 48 تنبيهًا من نوع SECURITY DEFINER callable by authenticated. هذا لا يعني أن كل دالة ثغرة؛ هذه هي RPC endpoints المقصودة للتطبيق، ويجب أن تبقى متاحة للمستخدم المسجل مع تحقق داخلي من الهوية والعضوية والصلاحيات. لا يجوز إزالة صلاحية authenticated بالجملة لأن التطبيق يعتمد على هذه RPCs. كما أظهر 4 جداول RLS بلا policies: `operation_counters` (مقصود: لا وصول مباشر عبر Data API) وثلاث جداول backup اختبارية قديمة لا تُنقل إلى Production.
10. **مراجعة دوال SECURITY DEFINER في Production:** الـAdvisor يعرض 17 دالة callable by authenticated، وكلها تمنع anon حسب فحص ACL. الثلاث دوال `add_business_member_by_email` و`list_business_members` و`update_business_member` لديها بالفعل `search_path=''` وتتحقق من عضوية المالك النشطة. من الـ14 المتبقية: 13 تستخدم `search_path=public`، و`restore_business_backup` القديمة تستخدم `public, pg_temp`. أُنشئ `PRODUCTION_SECURITY_DEFINER_SEARCH_PATH_PATCH.sql` لتغيير إعداد 13 توقيعًا فقط إلى مسار فارغ دون تغيير أجسامها أو صلاحياتها؛ واستبدال Restore الموجود في مسودة الترقية يستخدم أصلًا `search_path=''`. فحص التعابير أظهر أن مراجع الجداول/الدوال في 13 دالة كانت مؤهلة بالمخطط `public.`، ولم تظهر مراجع جداول غير مؤهلة. جميع الدوال الـ17 تحتوي فحص `auth.uid()`; 13 عملية تشغيلية تتحقق من الصلاحية عبر `has_business_permission`، ودوال العضوية/المالك تتحقق مباشرة من عضوية نشطة ودور owner. تحذير Advisor هنا لا يبرر إلغاء EXECUTE عن authenticated لأن هذه RPCs واجهة التطبيق، بينما anon غير مسموح له.
11. **Restore compatibility:** Restore Production الحالية لا تزال تقبل `alnesr-business-backup-v1` فقط، بينما المسودة الجديدة تدعم v2 وv3، مع استكمال جداول الإصدار الثاني وإضافات التوافق والتحقق من مراجع snapshots. لا نغيّر الدالة الحالية؛ يجب اعتماد المسودة الجديدة ضمن ترقية متكاملة.
12. **Auth Advisor:** أظهر أن leaked-password protection معطل في Test. لم يتم تغيير إعداد Auth، ويجب فحص إعداد Production مستقلًا قبل الإطلاق واتخاذ قرار واعٍ.

## حالة التحقق

- تم التحقق من حفظ ملف Restore المصحح.
- تم التحقق من حفظ helper hardening patch وفاحصه وملف `PRODUCTION_SECURITY_DEFINER_SEARCH_PATH_PATCH.sql`.
- لم يتم تشغيل patch أو الفاحص على Test أو Production.
- لا توجد نتيجة functional/concurrency test حتى الآن. لم يتم تنفيذ أي ALTER FUNCTION أو استبدال Restore.

## ترتيب المرحلة

بعد الجداول والأعمدة والعلاقات: شغّل helper base draft ثم `PRODUCTION_HELPER_FUNCTIONS_HARDENING_PATCH.sql`، ثم `verify_production_helper_functions.sql` على قاعدة اختبار معزولة. لا تُشغّل هذا الفاحص على Test الحالية قبل الترقية، ولا على Production قبل الموافقة الصريحة.
