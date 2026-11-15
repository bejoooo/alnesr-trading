-- The business was bootstrapped already. Public client accounts must never create new tenants.
-- Keep account signup available for staff onboarding; the owner adds them through staff management.
drop policy if exists businesses_creator_insert on public.businesses;
revoke insert on table public.businesses from public, anon, authenticated;
