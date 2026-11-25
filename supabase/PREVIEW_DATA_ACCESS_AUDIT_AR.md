# تدقيق وصول واجهة Preview إلى الجداول والـViews وStorage

تاريخ الفحص: 25 نوفمبر 2026  
ملف الواجهة: `preview/index.html` في `development`  
Blob: `786bdfab945aa605b8f317cb8dcace809bdd8b66`  
نوع الفحص: تحليل ساكن لاستدعاءات Supabase JS، مع مقارنة أسماء الكائنات بالمخطط.

## 1. الوصول المباشر

تستخدم الواجهة `.from()` على 24 كائنًا:

### جداول أساسية (18)
- `business_members`
- `businesses`
- `cash_transactions`
- `customer_credit_ledger`
- `expenses`
- `parties`
- `payments`
- `products`
- `purchase_invoices`
- `purchase_items`
- `purchase_return_items`
- `purchase_returns`
- `sales_invoices`
- `sales_items`
- `sales_return_items`
- `sales_returns`
- `stock_movements`
- `treasury_transfers`

### Views (6)
- `cash_balances`
- `customer_credit_balances`
- `customer_credit_return_balances`
- `party_account_balances`
- `party_account_statement`
- `product_stock_balances`

الواجهة لا تستخدم View `daily_business_summary` مباشرة عبر `.from()` في هذا الإصدار.

## 2. الكتابات المباشرة من الواجهة

الواجهة تنفذ كتابة مباشرة (بدون RPC) على ثلاثة جداول:
- `businesses`: تحديث الاسم والهاتف والعنوان و`tagline`.
- `products`: إدراج منتج، تحديث بيانات منتج، وإدراج منتج جديد من داخل فاتورة المشتريات.
- `parties`: إدراج عميل أو مورد.

لا يوجد `.delete()` مباشر على جداول قاعدة البيانات في مسارات الكتابة التي فُحصت؛ عمليات الحذف المباشرة الظاهرة تخص ملفات Storage المؤقتة/الصور، لا صفوف الجداول.

**أثر مباشر على الترقية:** عمود `businesses.tagline` يجب أن يُضاف قبل نشر الواجهة؛ وإلا فإن تحديث إعدادات النشاط الذي يرسل هذا الحقل سيفشل. كذلك يجب الحفاظ على سياسات INSERT/UPDATE الحالية لـproducts وparties، وعدم فرض كتابة RPC-only على هذه الجداول دون تعديل الواجهة (وهو خارج النطاق الحالي).

## 3. RPCs

- 41 موضع استدعاء `.rpc()` في النص.
- 37 اسم RPC فريدًا.
- 39 توقيعًا متوقعًا في Test بسبب overloads.

تفاصيل التواقيع موجودة في `RPC_COMPATIBILITY_MATRIX_AR.md`.

## 4. Storage

- الواجهة تستخدم bucket واحدًا: `product-images`.
- إعدادات bucket وسياساته الأربع متطابقة بين Test وProduction في المقارنة السابقة.
- عمليات الواجهة تشمل signed URLs، رفع الصور، حذف الملفات المؤقتة، وتجهيز صور النسخ الاحتياطي.
- يجب الحفاظ على bucket خاصًا وعدم فتحه للعامة. يجب اختبار صلاحيات upload/read/remove للمستخدمين وفق سياسات Storage الحالية، لا الاكتفاء بتطابق اسم bucket.

## 5. بوابات قبل نشر الواجهة

1. إضافة `businesses.tagline` قبل نشر نسخة Preview.
2. إنشاء الجداول والـViews الستة التي تقرؤها الواجهة قبل نشرها.
3. تحديث أعمدة وViews التي تستخدمها عمليات القراءة.
4. تثبيت سياسات RLS والـgrants على الجداول ذات الكتابة المباشرة.
5. الحفاظ على Storage bucket وسياساته.
6. إكمال كل RPCs المطلوبة ومطابقة التوقيعات.
7. عدم نشر الواجهة قبل نجاح فحوص schema/ACL/RLS/RPCs.

## الحدود

تحليل الاستدعاءات ساكن؛ لا يعني أن كل مسار واجهة اختُبر فعليًا. لم يتم تنفيذ إدراج أو تحديث أو حذف أو رفع ملفات في Test أو Production.
