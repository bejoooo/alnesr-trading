# حزمة تجهيز ترقية Production — دليل التنفيذ والمراجعة

تاريخ التحديث: 27 نوفمبر 2026  
الفرع التحضيري: `production-upgrade-prep-2026-11-27`  
الفرع الأصلي غير المعدّل: `development`

## قواعد لا تتغير

- هذه الحزمة للمراجعة والتحضير فقط؛ لا تشغّل أي ملف SQL قبل موافقة منفصلة وصريحة على التنفيذ المحدد.
- لا تُشغّل أي Migration أو DDL/DML على Production أو Test الحالية خلال التحضير.
- لا تنقل بيانات تشغيلية من Test إلى Production.
- Production تحتفظ بسجل النشاط وعضوية المالك. لا Reset ولا حذف للنشاط أو العضوية.
- لا تغيّر واجهة Preview ولا صيغة التكلفة التي اختبرها المستخدم. يجب نقل سلوك Test كما هو.
- لا تستخدم service_role key في المتصفح.
- لا تدمج هذا الفرع في development أو main تلقائيًا.

## ترتيب الحزمة المقترح

| الترتيب | الملف | الغرض | الحالة |
|---:|---|---|---|
| 0 | `PRODUCTION_PREFLIGHT_READONLY.sql` | فحص خط الأساس قبل أي ترقية | قراءة فقط |
| 0A | النسخة الاحتياطية اليدوية المحفوظة بتاريخ 2026-11-27 | نقطة رجوع قاعدة البيانات | تم إنشاء dump وفحص قائمة محتوياته؛ لم يُختبر restore فعليًا |
| 1 | `PRODUCTION_MISSING_COLUMNS_DRAFT.sql` | إضافة الأعمدة الناقصة مع إبقاء أكواد العمليات وسعر بند المرتجع nullable مؤقتًا | مسودة |
| 2 | `PRODUCTION_NEW_TABLES_DRAFT.sql` | إنشاء الجداول التشغيلية السبعة مع RLS والصلاحيات المحدودة | مسودة |
| 3 | `PRODUCTION_INDEXES_CHECKS_DRAFT.sql` | الفهارس الفريدة وفهارس الأداء وقيود CHECK الناقصة | مسودة جديدة |
| 4 | `PRODUCTION_STRUCTURAL_FK_DRAFT.sql` | مفاتيح/FKs مركبة same-business، مع فحوص cross-business | مسودة معدّلة |
| 5 | `PRODUCTION_HELPER_FUNCTIONS_TRIGGERS_DRAFT.sql` | دوال الأكواد والعدادات وTriggers الترقيم | مسودة |
| 5A | `PRODUCTION_HELPER_FUNCTIONS_HARDENING_PATCH.sql` | تقوية helpers بعد مراجعة تعريفاتها | مسودة |
| 6 | `PRODUCTION_VIEWS_DRAFT.sql` | تحديث Views الأرصدة والمخزون وكشف الحساب | مسودة |
| 7 | `PRODUCTION_RPC_TREASURY_PAYMENTS_DRAFT.sql` | RPC الخزنة والمدفوعات والمصروفات | مسودة |
| 8 | `PRODUCTION_RPC_POSTING_RETURNS_STOCK_DRAFT.sql` | RPC الشراء والبيع والمرتجعات والمخزون | مسودة |
| 9 | `PRODUCTION_RPC_OWNER_ACTIONS_DRAFT.sql` | الأرشفة والعكس والإلغاء وإجراءات المالك | مسودة |
| 10 | `PRODUCTION_BACKUP_RESTORE_DRAFT.sql` | توافق استعادة Backup v2/v3 | مسار منفصل واختبار مستقل مطلوب |
| 11 | `PRODUCTION_SECURITY_DEFINER_SEARCH_PATH_PATCH.sql` | توحيد search_path للدوال المشتركة القديمة | مسودة |
| 12 | `PRODUCTION_ACL_RLS_ALIGNMENT_DRAFT.sql` | صلاحية tagline وسياسة قراءة المدفوعات المطابقة للاختبار | مسودة جديدة |
| 13 | ملفات `verify_production_*.sql` | فحوص بنية وACL وViews وRPCs بعد كل مرحلة | قراءة فقط |

**مستبعد من مسار الترقية العادي:** `PRODUCTION_RESET_BUSINESS_DATA_DRAFT.sql`. لا حاجة لتصفير Production؛ لا تشغّل دالة reset.  
**مسار النشر:** Edge Function الحالية `app-preview` وGitHub Pages يظلان دون تغيير حتى اكتمال القاعدة وموافقة مستقلة على مسار التحويل.

## نقاط تحقق قبل اعتماد أي ملف

1. تأكيد أن جميع المتطلبات السابقة موجودة وأن أنواع الأعمدة والتواقيع تطابق Test.
2. فحص أي أكواد/قيود حالية وتكرارات قبل إنشاء الفهارس الفريدة.
3. التحقق من عدم وجود روابط بين نشاطين قبل اعتماد FKs المركبة.
4. مطابقة RLS وACL وSECURITY DEFINER وsearch_path لكل RPC.
5. فحص الصيغ المحاسبية: لا تُعدّل طريقة التكلفة المختبرة؛ قارن تعريفات Test ولا تعِد صياغتها.
6. لا تعتبر نجاح فاحص الكتالوج أو المراجعة الساكنة اختبارًا وظيفيًا.

## حدود الاختبار المتاحة حاليًا

- Test الحالية تحتوي بيانات اختبار يريد المستخدم الاحتفاظ بها للمقارنة، ولذلك تظل قراءة فقط.
- Production ليست بيئة اختبار؛ يجب الحفاظ على النشاط وعضوية المالك فيها.
- لم يتم حتى الآن توفير نسخة محلية معزولة مؤكدة التشغيل مع PostgreSQL وبدائل Auth/Storage. لا يُدّعى نجاح functional tests قبل توفيرها.
- النسخة الاحتياطية بصيغة custom dump قابلة للقراءة عبر `pg_restore --list`، لكن لم يُجرَ restore تجريبي بعد.

## سجل التغييرات في هذا الفرع

- إصلاح خطأ dollar-quoting في أول كتلتين PL/pgSQL في ملف العلاقات المركبة.
- إضافة أربعة روابط مركبة same-business: purchase_return_id وsales_return_id في payments وcash_transactions.
- إضافة مسودة الفهارس وقيود CHECK الناقصة.
- إضافة مسودة ACL ضيقة لعمود businesses.tagline وسياسة payments_read.
- تحديث بوابة متوسط التكلفة: المستخدم أكد اعتماد منطق Preview المختبر دون تغيير.
- لا توجد تغييرات على قواعد البيانات أو Auth أو Storage أو Edge Functions أو ملفات الواجهة.
