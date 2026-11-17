-- Correct catalog-only stock alerts and provide an owner-only product restore path.
CREATE OR REPLACE VIEW public.product_stock_balances
WITH (security_invoker = true)
AS
SELECT
  p.business_id,
  p.id AS product_id,
  p.code,
  p.name,
  p.unit,
  p.minimum_stock,
  COALESCE(sum(sm.quantity_delta), 0::numeric)::numeric(14,3) AS quantity_on_hand,
  p.average_cost,
  (COALESCE(sum(sm.quantity_delta), 0::numeric) * p.average_cost)::numeric(14,2) AS stock_value,
  (
    count(sm.id) > 0
    AND COALESCE(sum(sm.quantity_delta), 0::numeric) > 0
    AND COALESCE(sum(sm.quantity_delta), 0::numeric) <= p.minimum_stock
  ) AS below_minimum,
  (count(sm.id) > 0) AS has_stock_history,
  (
    count(sm.id) > 0
    AND COALESCE(sum(sm.quantity_delta), 0::numeric) <= 0
  ) AS out_of_stock
FROM public.products p
LEFT JOIN public.stock_movements sm
  ON sm.business_id = p.business_id
 AND sm.product_id = p.id
WHERE p.is_active = true
GROUP BY
  p.business_id, p.id, p.code, p.name, p.unit,
  p.minimum_stock, p.average_cost;

CREATE OR REPLACE FUNCTION public.owner_restore_product(
  p_business_id uuid,
  p_product_id uuid
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_is_active boolean;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1
    FROM public.business_members
    WHERE business_id = p_business_id
      AND user_id = auth.uid()
      AND role = 'owner'
      AND active = true
  ) THEN
    RAISE EXCEPTION 'Only the active business owner can restore products';
  END IF;

  SELECT is_active
    INTO v_is_active
  FROM public.products
  WHERE id = p_product_id
    AND business_id = p_business_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Archived product not found';
  END IF;

  IF v_is_active THEN
    RAISE EXCEPTION 'Product is already active';
  END IF;

  UPDATE public.products
  SET is_active = true,
      updated_at = now()
  WHERE id = p_product_id
    AND business_id = p_business_id;

  INSERT INTO public.audit_log(
    business_id, actor_id, action, entity_type, entity_id, details
  )
  VALUES (
    p_business_id, auth.uid(), 'restored', 'product', p_product_id,
    jsonb_build_object('restored', true)
  );

  RETURN 'restored';
END;
$function$;

REVOKE ALL ON FUNCTION public.owner_restore_product(uuid, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.owner_restore_product(uuid, uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.owner_restore_product(uuid, uuid) TO authenticated;
