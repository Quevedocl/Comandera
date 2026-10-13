-- kepasa · arreglo: "new row violates row-level security policy" al subir el logo
-- Pega y ejecuta esto en Supabase > SQL Editor. Es seguro ejecutarlo más de una vez.

-- 1) Que existan el bucket y la columna del logo
alter table restaurants add column if not exists logo_url text;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('logos', 'logos', true, 2097152, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/png','image/jpeg','image/webp'];

-- 2) Políticas: cada dueño sube/borra solo dentro de la carpeta de su restaurante
drop policy if exists logos_ins on storage.objects;
create policy logos_ins on storage.objects for insert to authenticated
  with check (bucket_id = 'logos' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));
drop policy if exists logos_del on storage.objects;
create policy logos_del on storage.objects for delete to authenticated
  using (bucket_id = 'logos' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));

-- 3) Que el dueño pueda actualizar nombre, logo, propina y estado del local
grant update (name, logo_url, tip_pct, open_now) on restaurants to authenticated;
drop policy if exists r_upd on restaurants;
create policy r_upd on restaurants for update to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
