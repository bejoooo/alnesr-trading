-- Al Nesr Trading — private product image storage
-- Apply AFTER 009_party_opening_balances.sql.
insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('product-images','product-images',false,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists product_images_read on storage.objects;
create policy product_images_read on storage.objects
for select to authenticated
using (
 bucket_id='product-images'
 and public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.view')
);

drop policy if exists product_images_insert on storage.objects;
create policy product_images_insert on storage.objects
for insert to authenticated
with check (
 bucket_id='product-images'
 and public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.create')
 and (storage.foldername(name))[2] is not null
);

drop policy if exists product_images_update on storage.objects;
create policy product_images_update on storage.objects
for update to authenticated
using (
 bucket_id='product-images'
 and public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.edit')
)
with check (
 bucket_id='product-images'
 and public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.edit')
);

drop policy if exists product_images_delete on storage.objects;
create policy product_images_delete on storage.objects
for delete to authenticated
using (
 bucket_id='product-images'
 and (
  public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.edit')
  or public.has_business_permission(((storage.foldername(name))[1])::uuid,'products.create')
 )
);
