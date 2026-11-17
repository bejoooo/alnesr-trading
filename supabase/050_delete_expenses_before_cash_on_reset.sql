do $$
declare
  v_def text;
  v_old text := $old$ -- Cash rows reference standalone payment rows; remove cash reversals and originals first.
 delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;
 delete from public.cash_transactions where business_id=p_business_id;

 -- Payment reversals reference original payments; remove reversals before originals.
 delete from public.payments where business_id=p_business_id and reversal_of_payment_id is not null;
 delete from public.payments where business_id=p_business_id;

 delete from public.sales_return_items where business_id=p_business_id;
 delete from public.expenses where business_id=p_business_id;$old$;
  v_new text := $new$ -- Expenses reference their original cash row with ON DELETE RESTRICT.
 -- Remove expense rows first, while preserving their linked cash rows until this point.
 delete from public.expenses where business_id=p_business_id;

 -- Cash rows may reference payments; remove cash reversals and originals before payments.
 delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;
 delete from public.cash_transactions where business_id=p_business_id;

 -- Payment reversals reference original payments; remove reversals before originals.
 delete from public.payments where business_id=p_business_id and reversal_of_payment_id is not null;
 delete from public.payments where business_id=p_business_id;

 delete from public.sales_return_items where business_id=p_business_id;$new$;
begin
 select pg_get_functiondef('public.reset_business_data(uuid)'::regprocedure) into v_def;
 if position(v_old in v_def)=0 then
   raise exception 'Expected reset deletion block was not found; migration stopped without changing the function';
 end if;
 v_def:=replace(v_def,v_old,v_new);
 if position('delete from public.expenses where business_id=p_business_id;' in v_def)
    > position('delete from public.cash_transactions where business_id=p_business_id and reversal_of_transaction_id is not null;' in v_def) then
   raise exception 'Expense deletion is not before cash deletion';
 end if;
 execute v_def;
end $$;
