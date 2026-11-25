# خط أساس بيانات Production قبل الترقية

تاريخ الفحص: 25 نوفمبر 2026  
المشروع: `njvaxrucfwgksqdfbckt`  
نوع الفحص: SELECT COUNT(*) لكل الجداول الأساسية الـ16 في public.

## النتيجة

| الجدول | الصفوف |
|---|---:|
| audit_log | 0 |
| business_members | 1 |
| business_settings | 0 |
| businesses | 1 |
| cash_transactions | 0 |
| expenses | 0 |
| parties | 0 |
| payments | 0 |
| products | 0 |
| purchase_invoices | 0 |
| purchase_items | 0 |
| sales_invoices | 0 |
| sales_items | 0 |
| sales_return_items | 0 |
| sales_returns | 0 |
| stock_movements | 0 |

## قواعد الحفاظ

- وجود نشاط واحد وعضوية واحدة حقيقة قائمة يجب الحفاظ عليها؛ لا تحذفهما ولا تعِد إنشاء النشاط من الصفر.
- الصفر في الجداول التشغيلية لا يعني أن قاعدة الإنتاج قابلة للاستبدال؛ يجب الاحتفاظ بمفاتيح النشاط والعضوية وسياسات الوصول وإعدادات Auth/Storage.
- يعاد تشغيل نفس جرد COUNT(*) بعد أي ترقية، ويجب أن تبقى بيانات النشاط والعضوية كما كانت، وألا تظهر صفوف مالية/تشغيلية جديدة من عملية الترقية نفسها.
- لا تنقل أي صفوف من Test إلى Production.
- هذا الجرد لا يشمل سجلات Auth الداخلية خارج public أو إعدادات Auth أو Storage objects؛ يجب فحصها منفصلًا قبل أي ترقية.

لم يتم تنفيذ أي كتابة أو تعديل على Production.
