# مراجعة تفصيلية لدوال SECURITY DEFINER في Production

تاريخ الفحص: 25 نوفمبر 2026  
المشروع: `njvaxrucfwgksqdfbckt`  
نوع الفحص: استخراج كل أجسام public SECURITY DEFINER وACL والإعدادات؛ لا تعديل.

## النتيجة العددية

- إجمالي الدوال: 20.
- قابلة للتنفيذ من `authenticated`: 17.
- قابلة للتنفيذ من `anon`: صفر.
- قابلة للتنفيذ من `PUBLIC`: صفر.
- إعدادات search_path:
  - 16 تستخدم `public` أو `public, pg_temp`.
  - 3 تستخدم `search_path=""`.
  - 1 تستخدم `pg_catalog`.

## الدوال التي تستخدم public أو public, pg_temp

| التوقيع | EXECUTE authenticated | ملاحظة الفحص |
|---|---|---|
| `add_business_creator_as_owner()` | لا | Trigger-only؛ لا يعتمد على auth.uid لأن هوية المنشئ تأتي من NEW.created_by، ويلزم فحص RLS/إنشاء النشاط |
| `guard_invoice_reference_business()` | لا | Trigger guard |
| `has_business_permission(uuid,text)` | نعم | يفحص auth.uid والعضوية والصلاحية |
| `has_business_role(uuid,text[])` | نعم | يفحص auth.uid والدور |
| `is_business_member(uuid)` | نعم | يفحص auth.uid والعضوية |
| `post_purchase(...)` | نعم | يتحقق من المستخدم وصلاحية المشتريات |
| `post_sale(...)` | نعم | يتحقق من المستخدم وصلاحية المبيعات |
| `post_sales_return(...)` | نعم | يتحقق من المستخدم وصلاحية المبيعات |
| `post_stock_adjustment(...)` | نعم | يتحقق من المستخدم وصلاحية المخزون |
| `record_cash_deposit(...)` | نعم | يتحقق من المستخدم وصلاحية الخزنة |
| `record_cash_opening_balance(...)` | نعم | يتحقق من المستخدم وصلاحية الإيداع |
| `record_cash_withdrawal(...)` | نعم | يتحقق من المستخدم وصلاحية الخزنة |
| `record_expense(...)` | نعم | يتحقق من المستخدم وصلاحية المصروفات |
| `record_invoice_payment(...)` | نعم | يتحقق من المستخدم وصلاحيات الطرف والفاتورة |
| `restore_business_backup(uuid,jsonb)` | نعم | يستخدم dynamic SQL؛ لا تغيّر search_path قبل مراجعة كل النص الديناميكي والأسماء |
| `set_party_opening_balance(...)` | نعم | يتحقق من المستخدم وصلاحية الأطراف |

## الدوال ذات search_path الفارغ

- `add_business_member_by_email(uuid,text,text)`
- `list_business_members(uuid)`
- `update_business_member(uuid,uuid,text,boolean,jsonb)`

## الدالة ذات pg_catalog

- `rls_auto_enable()`: لا EXECUTE مباشر لـauthenticated أو anon أو PUBLIC؛ وظيفة داخلية.

## تقييم المخاطر والإجراء المقترح

1. لا توجد في لقطة ACL دالة SECURITY DEFINER قابلة للتنفيذ من anon أو PUBLIC.
2. الدوال التشغيلية التي تقبل authenticated تتحقق من auth.uid والصلاحيات وفق الفحص الساكن؛ لا يكفي ذلك وحده لإثبات سلامة كل مساراتها.
3. لا نحول كل الدوال إلى SECURITY INVOKER؛ بعضها يستلزم سياقًا مميزًا للوصول المقصود، ويجب مراجعة سبب SECURITY DEFINER لكل دالة.
4. نراجع كل مراجع الجداول/الدوال غير المؤهلة داخل الدوال ذات `search_path=public`، ثم نحولها إلى أسماء schema-qualified ونضبط search_path الفارغ فقط حيث يكون ذلك آمنًا.
5. `restore_business_backup` يحتاج مراجعة مستقلة بسبب dynamic SQL والتوافق مع إصدارات النسخ الاحتياطي.
6. لا ننسخ تعريفات Production القديمة إلى الحزمة الجديدة. نستخدم تعريفات Test الحالية بعد فحص ACL والاعتماديات، ونحافظ على EXECUTE لـauthenticated فقط عند الحاجة.
7. نعيد تشغيل Security Advisors بعد أي Migration، ثم نعيد استخراج ACL والـsearch_path.

## الحدود

هذه مراجعة ساكنة لأجسام الدوال وACL، وليست اختبار اختراق أو إثباتًا رسميًا لعدم وجود ثغرات. لم يتم تعديل أي دالة أو ACL.
