# نتائج فحص Production قبل الترقية — قراءة فقط

تاريخ الفحص: 25 نوفمبر 2026  
المشروع: `njvaxrucfwgksqdfbckt`  
الملف القابل لإعادة التشغيل: `PRODUCTION_PREFLIGHT_READONLY.sql`

## 1. عدد السجلات الحالي

| الجدول | العدد |
|---|---:|
| businesses | 1 |
| business_members | 1 |
| products | 0 |
| parties | 0 |
| purchase_invoices | 0 |
| purchase_items | 0 |
| sales_invoices | 0 |
| sales_items | 0 |
| payments | 0 |
| stock_movements | 0 |
| sales_returns | 0 |
| sales_return_items | 0 |
| expenses | 0 |
| cash_transactions | 0 |
| business_settings | 0 |
| audit_log | 0 |

## 2. سلامة النشاط والعضوية

- نشاط واحد موجود، وcreated_by مرتبط بمستخدم Auth موجود.
- عضوية واحدة مرتبطة بالنشاط الصحيح ومستخدم Auth موجود.
- العضوية نشطة، ودور owner نشط واحد.
- لم تُعرض معرفات المستخدمين أو بياناتهم الشخصية في التقرير.

## 3. RLS

- كل الجداول الأساسية الـ16 في Production عليها RLS مفعّل.
- `FORCE ROW LEVEL SECURITY` غير مفعّل على هذه الجداول؛ هذا هو الوضع الحالي ولا يتم تغييره بالجملة. يجب الحفاظ على سلوك SECURITY DEFINER/RLS المقصود عند الترقية.

## 4. Storage

- bucket `product-images` موجود وخاص.
- الحد الأقصى 5MB.
- MIME المسموح: JPEG وPNG وWebP.
- عدد ملفات Storage في هذا الـbucket: صفر.

## 5. سجل Migrations

- عدد سجلات `supabase_migrations.schema_migrations`: 19.

## 6. الاستنتاج

لا توجد حاليًا فواتير أو حركات مخزون أو دفعات أو حركات خزنة أو مصروفات في جداول Production التي تم جردها. لكن هذا لا يعني أن Production فارغة: يجب الحفاظ على النشاط والمالك والعضوية الموجودة كما هي.

يُعاد تشغيل `PRODUCTION_PREFLIGHT_READONLY.sql` مباشرة قبل أي ترقية وبعدها، وتقارن النتائج. أي اختلاف غير متوقع في النشاط أو العضوية أو البيانات يوقف خطة الترقية.

لم يتم تنفيذ DDL أو DML أو تعديل Auth/Storage/Edge Function.
