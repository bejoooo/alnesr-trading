# مصفوفة تغطية مصادر Migrations بين Test والمستودع

آخر تحديث: 25 نوفمبر 2026  
المستودع: `bejoooo/alnesr-trading`  
الفرع: `development`

## المنهج

- تمت قراءة 118 سجلًا من `supabase_migrations.schema_migrations` في Test.
- تمت قراءة أسماء ملفات SQL في `supabase/` بفرع development.
- المطابقة المباشرة تعني تطابق الاسم بعد إزالة بادئة رقم الملف فقط؛ لا تعني أن الملف آمن لإعادة التشغيل.
- عدم وجود تطابق مباشر لا يعني تلقائيًا فقدان التغيير؛ قد يكون التغيير مدمجًا في ملف أحدث أو تم حفظ تعريفه النهائي فقط.
- لا نعتبر الملف المجمع بديلًا أصليًا إلا بعد مطابقة كائناته وتعريفاتها مع Test.
- هذه المصفوفة لا تصرح بتشغيل أي ملف SQL.

## ملخص رقمي

| البند | العدد |
|---|---:|
| سجلات Test | 118 |
| ملفات SQL في المجلد (بما فيها schema وverify) | 64 |
| سجلات لها ملف مطابق بالاسم | 41 |
| سجلات بلا ملف مطابق بالاسم | 77 |
| ملفات المصدر غير الممثلة كسجل مطابق | 23 |

## أ — السجلات ذات المصدر المطابق بالاسم

هذه مطابقة اسمية فقط؛ يلزم دائمًا فحص الاعتماديات وحالة الكائنات قبل أي إعادة استخدام.

| Migration version | الاسم المسجل في Test | ملف المصدر |
|---|---|---|
| 20261115064451 | `staff_management` | `013_staff_management.sql` |
| 20261115115846 | `015_membership_policy_performance` | `015_membership_policy_performance.sql` |
| 20261115120324 | `016_foreign_key_indexes` | `016_foreign_key_indexes.sql` |
| 20261115121551 | `017_payment_visibility_by_invoice_permission` | `017_payment_visibility_by_invoice_permission.sql` |
| 20261115151205 | `018_owner_only_staff_management` | `018_owner_only_staff_management.sql` |
| 20261115152946 | `restrict_direct_master_data_writes` | `019_restrict_direct_master_data_writes.sql` |
| 20261115153212 | `revoke_destructive_api_privileges` | `020_revoke_destructive_api_privileges.sql` |
| 20261115153353 | `party_opening_balance_integrity` | `021_party_opening_balance_integrity.sql` |
| 20261115153419 | `fix_invoice_party_lock_trigger` | `022_fix_invoice_party_lock_trigger.sql` |
| 20261115153522 | `customer_return_average_cost` | `023_customer_return_average_cost.sql` |
| 20261115153644 | `revoke_trigger_function_execute` | `024_revoke_trigger_function_execute.sql` |
| 20261115153733 | `revoke_remaining_trigger_function_execute` | `025_revoke_remaining_trigger_function_execute.sql` |
| 20261115154043 | `safe_default_api_privileges` | `026_safe_default_api_privileges.sql` |
| 20261115154143 | `revoke_global_public_function_execute` | `027_revoke_global_public_function_execute.sql` |
| 20261115154244 | `rpc_only_ledger_writes` | `028_rpc_only_ledger_writes.sql` |
| 20261115154350 | `read_only_defaults_for_new_tables` | `029_read_only_defaults_for_new_tables.sql` |
| 20261115193406 | `disable_public_business_creation` | `030_disable_public_business_creation.sql` |
| 20261117092407 | `040_standalone_party_payments` | `040_standalone_party_payments.sql` |
| 20261117092457 | `041_align_party_statements_for_standalone_payments` | `041_align_party_statements_for_standalone_payments.sql` |
| 20261117092555 | `042_mark_standalone_party_statement_entries` | `042_mark_standalone_party_statement_entries.sql` |
| 20261117092731 | `043_hide_reversal_action_for_reversed_standalone_payments` | `043_hide_reversal_action_for_reversed_standalone_payments.sql` |
| 20261117121907 | `044_net_standalone_payment_reversals_in_daily_reports` | `044_net_standalone_payment_reversals_in_daily_reports.sql` |
| 20261117122013 | `045_reset_cash_before_standalone_payments` | `045_reset_cash_before_standalone_payments.sql` |
| 20261117122149 | `046_validate_standalone_payment_account_type_and_party_state` | `046_validate_standalone_payment_account_type_and_party_state.sql` |
| 20261117152744 | `047_fix_sales_return_cancel_row_lock` | `047_fix_sales_return_cancel_row_lock.sql` |
| 20261117152828 | `048_keep_sales_invoice_status_within_allowed_values` | `048_keep_sales_invoice_status_within_allowed_values.sql` |
| 20261117152945 | `049_reject_archived_customers_and_products_on_sale` | `049_reject_archived_customers_and_products_on_sale.sql` |
| 20261117154244 | `050_delete_expenses_before_cash_on_reset` | `050_delete_expenses_before_cash_on_reset.sql` |
| 20261117155849 | `051_harden_backup_restore_integrity` | `051_harden_backup_restore_integrity.sql` |
| 20261117160204 | `052_idempotent_audit_restore` | `052_idempotent_audit_restore.sql` |
| 20261117161323 | `053_restrict_cashier_manual_cash_permissions` | `053_restrict_cashier_manual_cash_permissions.sql` |
| 20261117203858 | `054_fix_catalog_stock_alerts_and_archive_restore` | `054_fix_catalog_stock_alerts_and_archive_restore.sql` |
| 20261119221509 | `use_original_payment_code_for_reversals` | `055_use_original_payment_code_for_reversals.sql` |
| 20261120062724 | `057_multi_account_deposits_withdrawals` | `057_multi_account_deposits_withdrawals.sql` |
| 20261124202631 | `align_treasury_balance_sources` | `058_align_treasury_balance_sources.sql` |
| 20261125041118 | `exclude_customer_credit_payouts_from_party_statement` | `059_exclude_customer_credit_payouts_from_party_statement.sql` |
| 20261125041253 | `keep_customer_credit_payouts_in_party_statement` | `060_keep_customer_credit_payouts_in_party_statement.sql` |
| 20261125044352 | `preserve_average_cost_on_sales_return_reversal` | `061_preserve_average_cost_on_sales_return_reversal.sql` |
| 20261125050218 | `complete_business_backup_and_reset_for_new_tables` | `062_complete_business_backup_and_reset_for_new_tables.sql` |
| 20261125050336 | `preserve_legacy_v2_backup_restore_compatibility` | `063_preserve_legacy_v2_backup_restore_compatibility.sql` |
| 20261125054058 | `independent_treasury_transfer_permissions` | `058_independent_treasury_transfer_permissions.sql` |

## ب — السجلات بلا ملف مطابق بالاسم

المراجع المجمعة أدناه مرشحات مبنية على الكائنات التي تعيد الملفات تعريفها. لا تعني أن التغيير التاريخي الأصلي محفوظ حرفيًا أو أن كل أثره موجود.

| Migration version | الاسم المسجل في Test | مرجع مصدر محتمل | التصنيف |
|---|---|---|---|
| 20261116175954 | `add_owner_business_data_reset` | 031_preserve_payment_reversals_and_reporting.sql; 037_preserve_stock_reversals_in_reset_and_restore.sql; 062_complete_business_backup_and_reset_for_new_tables.sql — تغطية جزئية لدوال reset/restore | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261116190419 | `automatic_invoice_numbering_preview` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261116191902 | `safe_owner_delete_archive_and_invoice_void` | 031–034 — تعريفات owner_void_invoice وإجراءات الحذف/الأرشفة؛ يلزم مطابقة نهائية | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261116192358 | `safe_owner_cash_and_expense_reversals` | 032_preserve... / 038_preserve_expense_history_and_report_integrity.sql — دوال عكس الخزنة والمصروفات | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261116200722 | `019_idempotent_cash_reversals_and_expense_links` | 031/032/034/038 — مرشحات نهائية لمسارات العكس والربط | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117035206 | `020_safe_stock_adjustment_and_opening_balance_reversals` | 032/033 — تعريفات عكس حركات المخزون | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117035236 | `021_safe_non_cash_sales_return_reversal` | 032/033/061 — مسار إلغاء المرتجع وتكلفة المخزون | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117035246 | `022_fix_same_return_stock_guard` | 033_lock_products_during_stock_reversals.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117035411 | `023_aggregate_sales_return_quantity_guard` | 033_lock_products_during_stock_reversals.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117044411 | `fix_backup_snapshots_and_reset_order` | 037_preserve_stock_reversals_in_reset_and_restore.sql; 062/063 — مسارات reset/restore | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117044439 | `guard_sale_void_against_later_stock` | 031/033/034 — owner_void_invoice | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117044451 | `index_cost_snapshot_foreign_keys` | 016_foreign_key_indexes.sql — يلزم مقارنة الفهارس الحالية | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117044508 | `align_restore_with_backup_v2` | 037/062/063 — restore compatibility | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117053305 | `fix_expense_cash_order_reset_restore` | 038_preserve_expense_history_and_report_integrity.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117053802 | `link_and_safely_void_sales_returns` | 032/033 — دوال owner_remove_sales_return/post_sales_return | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117053859 | `align_reset_restore_with_return_links` | 037/062/063 | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055134 | `preserve_invoice_payment_history_on_void` | 031/034 — owner_void_invoice وrecord_invoice_payment | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055210 | `make_party_balance_view_security_invoker` | 012_secure_rpc_and_payment_reporting.sql أو 031 — يلزم إثبات security_invoker من النص النهائي | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055248 | `net_supplier_payment_reversals_in_party_balances` | 031/036 — تعريف party_account_balances | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055415 | `order_reversal_rows_for_reset_and_restore` | 037_preserve_stock_reversals_in_reset_and_restore.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055710 | `exclude_voided_transactions_from_account_and_daily_views` | 031_preserve_payment_reversals_and_reporting.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055728 | `restrict_payment_methods_to_supported_options` | 035_align_lock_order_for_cash_and_stock_posting.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117055855 | `skip_already_reversed_return_payments_when_voiding_invoice` | 033/034 — owner_void_invoice/owner_remove_sales_return | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117060034 | `exclude_voided_return_payment_reversals_from_daily_summary` | 031_preserve_payment_reversals_and_reporting.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062444 | `use_actual_posting_timestamps_for_safe_reversals` | 032_actual_posting_timestamps_for_reversals.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062508 | `lock_products_during_stock_posting_and_reversals` | 033_lock_products_during_stock_reversals.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062557 | `normalize_payment_methods_and_block_void_invoice_payments` | 034_harden_invoice_payment_recording_and_void_reconciliation.sql; 035 — يلزم مراجعة التغييرات النهائية | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062629 | `align_cash_and_product_lock_order_for_posting` | 035_align_lock_order_for_cash_and_stock_posting.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062701 | `net_return_refund_reversals_in_customer_balances` | 036_net_return_refund_reversals_in_party_balances.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117062742 | `preserve_stock_reversal_order_in_reset_and_restore` | 037_preserve_stock_reversals_in_reset_and_restore.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117063226 | `preserve_cancelled_expenses_and_audit_history_in_backups` | 038_preserve_expense_history_and_report_integrity.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117063313 | `label_expense_cancellation_audit_action` | 038_preserve_expense_history_and_report_integrity.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117063347 | `remove_duplicate_expense_index_and_index_voided_by` | 039_remove_duplicate_expense_index.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261117220402 | `055_reverse_invoice_payment` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261117220446 | `056_preserve_invoice_payment_cash_linkage` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261118061403 | `restore_archived_customer_accounts` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261118061804 | `allow_restore_archived_suppliers` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261118103342 | `owner_reverse_customer_invoice_payment` | 058_align_treasury_balance_sources.sql — يحتوي التعريف الحالي للدالة | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261118104139 | `fix_customer_invoice_payment_reversal_status_constraint` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261118184842 | `backup_test_data_before_reset_20261118` | — | اختباري فقط — لا يُنقل إلى Production |
| 20261119054801 | `add_customer_net_collected_balance` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261120011002 | `backup_test_data_before_full_retest_20261120` | — | اختباري فقط — لا يُنقل إلى Production |
| 20261120063526 | `expenses_from_selected_treasury_method` | 058_align_treasury_balance_sources.sql — يحتوي record_expense/record_treasury_withdrawal | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120074258 | `invoice_payment_methods` | 058_align_treasury_balance_sources.sql — يحتوي تعريفات الدفعات الحديثة؛ لا يثبت مصدر DDL | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120074435 | `invoice_payment_method_permissions` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261120143842 | `invoice_payment_methods` | 058_align_treasury_balance_sources.sql — يحتوي تعريفات الدفعات الحديثة؛ لا يثبت مصدر DDL | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120144000 | `include_manual_non_cash_movements_when_voiding_sales` | 058_align_treasury_balance_sources.sql — يحتوي owner_void_invoice | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120150533 | `sales_return_refund_payment_method` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261120161028 | `editable_return_unit_prices` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261120162417 | `purchase_return_supplier_refund_method` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261120162454 | `fix_supplier_return_offset_balance` | 058_align_treasury_balance_sources.sql — يحتوي owner_void_purchase_return؛ تغطية جزئية | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120163045 | `add_safe_purchase_return_cancellation` | 058_align_treasury_balance_sources.sql — يحتوي owner_void_purchase_return | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120184814 | `prevent_duplicate_non_cash_treasury_movements` | 058_align_treasury_balance_sources.sql — يحتوي دوال الخزنة/العكس | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120204517 | `add_treasury_transfer_reversal` | 058_independent_treasury_transfer_permissions.sql — يحتوي create/reverse treasury transfer | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261120205333 | `include_zero_stock_in_low_stock_alerts` | 054_fix_catalog_stock_alerts_and_archive_restore.sql | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261121053025 | `tighten_reset_business_data_search_path` | 062_complete_business_backup_and_reset_for_new_tables.sql — يحتوي reset_business_data النهائي | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261121053245 | `tighten_has_business_permission_search_path` | 058_independent_treasury_transfer_permissions.sql — يحتوي has_business_permission | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261121053331 | `tighten_has_business_role_search_path` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261121053442 | `tighten_is_business_member_search_path` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261121053617 | `tighten_add_business_creator_as_owner_search_path` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261121054747 | `revoke_unneeded_select_on_internal_tables` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261121055207 | `add_missing_foreign_key_indexes` | 016_foreign_key_indexes.sql — يلزم فحص الفهارس النهائية | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261121104113 | `revoke_direct_next_operation_code_execute` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261122114551 | `add_business_tagline` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123045520 | `customer_return_credit_and_settlement` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123045801 | `reverse_customer_credit_applications_and_payouts` | 058_align_treasury_balance_sources.sql — يحتوي pay_customer_credit وبعض دوال العكس؛ لا يغطي وحده كل migration | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123050044 | `secure_customer_credit_views_with_rls` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123050114 | `index_customer_credit_ledger_foreign_keys` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123051001 | `fix_customer_credit_payout_permissions_and_cash_balance` | 058_align_treasury_balance_sources.sql — يحتوي pay_customer_credit ومراجعات رصيد الخزنة | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123051007 | `fix_standalone_payment_cash_balance_check` | 058_align_treasury_balance_sources.sql — يحتوي record_standalone_party_payment | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123051009 | `fix_invoice_void_cash_balance_check` | 058_align_treasury_balance_sources.sql — يحتوي owner_void_invoice | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123051015 | `limit_sales_return_cash_to_actual_collections` | لا يوجد مصدر مباشر لدالة post_sales_return في ملفات 058؛ يلزم استعادة/إعادة بناء | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123054633 | `supplier_return_deferred_credit_and_receipt` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123054648 | `secure_supplier_statement_view_invoker` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123054730 | `serialize_supplier_credit_application_on_purchase` | — | لا يوجد ملف مصدر مباشر معروف — يلزم استعادة المصدر أو إعادة بناء موثقة من Test |
| 20261123054804 | `allow_purchase_return_void_after_receipt_reversal` | 058_align_treasury_balance_sources.sql — يحتوي owner_void_purchase_return؛ يلزم مطابقة القيود والـRPC | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |
| 20261123175601 | `make_supplier_credit_application_opt_in` | 058_align_treasury_balance_sources.sql — يحتوي post_purchase_with_method؛ تغطية محتملة فقط | مرجع مجمّع محتمل — لا يُعتبر مصدرًا أصليًا ولا يُشغّل قبل مطابقة التعريفات |

## ج — استنتاجات مؤكدة من فحص ملفات المصدر

1. الملف `031_preserve_payment_reversals_and_reporting.sql` يعيد تعريف `owner_void_invoice`, `reset_business_data`, `restore_business_backup` وثلاث Views؛ لذلك قد يغطي أجزاء من عدة migrations تاريخية، لكنه لا يعيد كل تغييراتها الأصلية.
2. الملفات `032`–`038` تقدم تعريفات نهائية متعاقبة لدوال العكس، قفل المخزون، معالجة الدفعات، ترتيب الأقفال، أرصدة المرتجعات، reset/restore، وسجل المصروفات.
3. `040_standalone_party_payments.sql` يحتوي دوال الدفعات المستقلة وViews وسياسة `payments_read`; الملفات `041`–`043` لا تضيف تغييرات مستقلة (No-op متطابقة المحتوى).
4. `057_multi_account_deposits_withdrawals.sql` يحتوي دوال الإيداع والسحب والتحويل وتعريفات Views ذات الصلة.
5. `058_align_treasury_balance_sources.sql` يحتوي تعريفات نهائية لـ12 دالة مالية/تشغيلية؛ لكنه لا ينشئ الجداول الجديدة أو سياسات RLS الخاصة بدفتر الرصيد الدائن أو مرتجعات المشتريات.
6. `058_independent_treasury_transfer_permissions.sql` يحتوي دوال صلاحيات التحويل وقراءة الأرصدة والتحويل والعكس وسياسة قراءة التحويلات.
7. `059` و`060` نسختان متعاقبتان من تعريف `party_account_statement`; يعتمد الاختيار على آخر تعريف معتمد في Test، لا على تشغيل الملفين بترتيب عشوائي.
8. `061` يعالج لقطة متوسط التكلفة وعكس مرتجع المبيعات.
9. `062` و`063` يعالجان reset/restore والتوافق مع backup v2؛ يبقيان في مسار صيانة منفصل.

## د — ملفات/تغييرات لا يوجد لها مصدر تاريخي مباشر واضح

- `055_reverse_invoice_payment` و`056_preserve_invoice_payment_cash_linkage`: لا يوجد مصدر أصلي لهما في المستودع. الملف `055_use_original_payment_code_for_reversals.sql` مختلف تمامًا، ويعيد تعريف View كشف الحساب.
- `customer_return_credit_and_settlement`, `reverse_customer_credit_applications_and_payouts`, `secure_customer_credit_views_with_rls`, `index_customer_credit_ledger_foreign_keys`: توجد تعريفات حالية لبعض RPCs في Test، لكن لا يوجد ملف تأسيسي واضح ينشئ الجدول/الـViews والسياسات والفهارس بالكامل.
- `supplier_return_deferred_credit_and_receipt`, `secure_supplier_statement_view_invoker`, `serialize_supplier_credit_application_on_purchase`, `allow_purchase_return_void_after_receipt_reversal`, `make_supplier_credit_application_opt_in`: يوجد جزء من منطق الإلغاء/الشراء في تعريفات لاحقة، لكن مصدر إنشاء البنية ومسار استلام الرصيد الدائن وسياسات العرض غير محفوظ كملف تاريخي مستقل.
- `add_business_tagline`, `automatic_invoice_numbering_preview`, وبعض تغييرات استعادة الحسابات/قيود الحالة والصلاحيات تحتاج استعادة المصدر أو إعادة بناء موثقة من تعريفات Test الحالية.
- Migrationا النسخ الاحتياطي التجريبيين `backup_test_data_before_reset_20261118` و`backup_test_data_before_full_retest_20261120` لا ينقلان إلى Production.

## هـ — فحص 055/056 في Test مقابل Production

في Test توجد التعريفات التالية:
- `record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text)`: 5,205 بايت، SECURITY DEFINER، `search_path=""`.
- `owner_reverse_invoice_payment(uuid,uuid)`: 4,113 بايت، SECURITY DEFINER، `search_path=""`.
- `owner_reverse_customer_invoice_payment(uuid,uuid)`: 5,640 بايت، SECURITY DEFINER، `search_path=""`.

في Production:
- يوجد `record_invoice_payment` بالتوقيع نفسه لكن تعريفه 3,748 بايت وبـ`search_path=public`.
- لا يوجد `owner_reverse_invoice_payment` أو `owner_reverse_customer_invoice_payment` ضمن الاستعلام الحالي.
- هذا يثبت أن الحالة النهائية مختلفة، لكنه لا يستعيد نص Migration الأصلي 055/056. يجب استخراج التعريفات الحالية من Test وإعادة بناء Migration additive مع مراجعة أعمدة وروابط `payments` و`cash_transactions` وقيود منع العكس المكرر.

## و — الخطوة التالية

1. إعداد خريطة كائنات لكل مجموعة مرشحة: الجداول والأعمدة والقيود والفهارس والسياسات والـViews والـRPCs والـTriggers.
2. مقارنة التعريف النهائي في Test مع محتوى الملف المجمع لتحديد التغييرات التي يغطيها فعلًا.
3. وضع كل تغيير في واحدة من الحالات: مصدر كامل، مصدر جزئي، مصدر مفقود، اختبار فقط، أو لا يلزم نقله لأن الحالة النهائية موجودة.
4. استخراج التعريفات الحالية الناقصة من Test لبناء حزمة additive جديدة، مع preconditions/postconditions.
5. عدم تطبيق أي شيء على Production قبل مراجعة الحزمة والحصول على موافقة صريحة.

## حدود هذه المراجعة

كل ما سبق قراءة GitHub وSELECT من Test/Production. لم تُنفذ DDL/DML، ولم تُنقل بيانات، ولم تُعدل قواعد البيانات.
