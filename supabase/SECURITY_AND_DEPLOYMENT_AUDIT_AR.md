# مراجعة Advisors وEdge Functions قبل تحويل التطبيق

تاريخ الفحص: 25 نوفمبر 2026  
البيئتان: Test وProduction  
نوع الفحص: Supabase project metadata وAdvisors وقراءة كود Edge Function، دون تعديل.

## حالة المشروعين

- Test `alnesr-trading-test`: ACTIVE_HEALTHY، PostgreSQL 17.11.
- Production: ACTIVE_HEALTHY، PostgreSQL 17.11.
- لا توجد Edge Functions في Test.
- توجد Edge Function واحدة في Production باسم `app-preview`، ACTIVE، version 3، و`verify_jwt=false`.

## نتائج Security Advisors

### Test
- `authenticated_security_definer_function_executable`: تحذير على 48 دالة قابلة للاستدعاء من authenticated.
- `rls_enabled_no_policy`: 4 جداول؛ ثلاثة جداول backup اختبارية، و`operation_counters`.
- `auth_leaked_password_protection`: تحذير واحد.
- لا توجد ملاحظات Health.

### Production
- `authenticated_security_definer_function_executable`: تحذير على 17 دالة.
- `auth_leaked_password_protection`: تحذير واحد.
- لا توجد ملاحظات Health.
- لا توجد ملاحظات Security أخرى في لقطة الفحص.

تحذير SECURITY DEFINER لا يعني وحده أن الدالة قابلة لتجاوز الصلاحيات؛ بعض RPCs يجب أن تكون SECURITY DEFINER لتعمل عبر API، لكن يجب أن تتحقق داخليًا من `auth.uid()`, العضوية، الدور والصلاحية، وأن تستخدم `search_path` آمنًا، وألا تمنح EXECUTE لـanon/PUBLIC. سبق فحص مجموعة من الدوال الحساسة؛ ولا يزال يلزم تدقيق نهائي لكل دوال Production قبل النقل.

## Performance Advisors

- Test: تحذير معلوماتي عن 14 فهرسًا غير مستخدم، وفهرس/جدول اختبار بلا PK.
- Production: تحذير معلوماتي عن 32 فهرسًا غير مستخدم.
- لا نحذف أي فهرس بناءً على هذه المؤشرات وحدها؛ نشاط البيانات محدود جدًا، وبعض الفهارس مخصصة لاستعلامات لم تُنفذ بعد.

## Auth

كلا المشروعين يظهر تحذير `auth_leaked_password_protection`. لم يتم تفعيل/تغيير إعداد Auth خلال المراجعة؛ يلزم تقييمه كإعداد أمني مستقل، وعدم ربطه بترقية المخطط أو تغيير تجربة المستخدم دون قرار واضح.

## Edge Function: app-preview

- الدالة تقدم صفحة HTML عامة فقط، لذلك `verify_jwt=false` يسمح بتحميل الصفحة دون JWT. تسجيل الدخول يتم من الواجهة عبر Supabase Auth.
- كود HTML يتصل بقاعدة Production ويحتوي publishable key عام.
- فحص النص لم يظهر مفتاح service-role فعليًا؛ الظهور الوحيد لعبارة `service_role` كان في تحذير داخل واجهة الصفحة بعدم وضعه في ملف الإعدادات.
- الدالة ليست نسخة من Preview الحالية؛ لا تحتوي استدعاءات RPC الحديثة التي تعتمد عليها الواجهة الحالية.
- لا يتم حذفها أو تحديثها أثناء هذه المرحلة؛ تبقى مسار رجوع حتى اعتماد التحويل النهائي.

## القرار

1. لا تغيير في إعداد Auth أو Advisors أو Edge Function الآن.
2. تدقيق SECURITY DEFINER وACL/search_path جزء إلزامي من مراجعة حزمة Production.
3. عدم حذف unused indexes حتى تتوفر بيانات تشغيلية كافية وخطة قياس.
4. الحفاظ على `app-preview` كمسار نشر قائم إلى حين نجاح مسار الواجهة الجديدة.
5. كل نتائج هذا الملف من metadata وقراءات فقط.
