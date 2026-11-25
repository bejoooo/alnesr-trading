-- DRAFT ONLY: harden the remaining Production SECURITY DEFINER RPC search paths.
-- Source audit confirmed every relation and helper reference in these bodies is schema-qualified.
-- No function bodies, grants, or financial behavior are changed by this patch.
-- Do not execute on Test or Production without the approved isolated upgrade sequence.
begin;
alter function public.has_business_permission(uuid,text) set search_path='';
alter function public.has_business_role(uuid,text[]) set search_path='';
alter function public.is_business_member(uuid) set search_path='';
alter function public.post_purchase(uuid,text,uuid,date,jsonb,numeric,numeric,text) set search_path='';
alter function public.post_sale(uuid,text,uuid,date,jsonb,numeric,numeric,text) set search_path='';
alter function public.post_sales_return(uuid,text,uuid,jsonb,numeric,date,text) set search_path='';
alter function public.post_stock_adjustment(uuid,uuid,numeric,text,date,numeric) set search_path='';
alter function public.record_cash_deposit(uuid,numeric,text,date,text) set search_path='';
alter function public.record_cash_opening_balance(uuid,numeric,date,text) set search_path='';
alter function public.record_cash_withdrawal(uuid,numeric,text,date,text) set search_path='';
alter function public.record_expense(uuid,text,numeric,date,text) set search_path='';
alter function public.record_invoice_payment(uuid,text,uuid,numeric,date,text,text,text) set search_path='';
alter function public.set_party_opening_balance(uuid,uuid,numeric,text) set search_path='';
-- The draft replacement for restore_business_backup already declares search_path=''.
commit;
