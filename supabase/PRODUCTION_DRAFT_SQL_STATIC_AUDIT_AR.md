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
9. **Auth Advisor:** أظهر أن leaked-password protection معطل في Test. لم يتم تغيير إعداد Auth، ويجب فحص إعداد Production مستقلًا قبل الإطلاق واتخاذ قرار واعٍ.

## حالة التحقق

- تم التحقق من حفظ ملف Restore المصحح.
- تم التحقق من حفظ helper hardening patch وفاحصه.
- لم يتم تشغيل patch أو الفاحص على Test أو Production.
- لا توجد نتيجة functional/concurrency test حتى الآن.

## ترتيب المرحلة

بعد الجداول والأعمدة والعلاقات: شغّل helper base draft ثم `PRODUCTION_HELPER_FUNCTIONS_HARDENING_PATCH.sql`، ثم `verify_production_helper_functions.sql` على قاعدة اختبار معزولة. لا تُشغّل هذا الفاحص على Test الحالية قبل الترقية، ولا على Production قبل الموافقة الصريحة.
