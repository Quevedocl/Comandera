-- Fogón · migración 6: "Abierto ahora / Local cerrado"
-- Ejecutar UNA vez en Supabase > SQL Editor (después de las migraciones anteriores). Es seguro repetirla.
-- Hazlo ANTES de subir los HTML nuevos.

alter table restaurants add column if not exists open_now boolean not null default true;

-- Con el local cerrado nadie puede crear pedidos nuevos (las mesas abiertas siguen pudiendo llamar al mesero y pedir la cuenta)
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert to anon, authenticated with check (status = 'pending' and restaurant_id is not null and exists (select 1 from restaurants r where r.id = restaurant_id and r.active and r.open_now) and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id and d.session_id = orders.session_id)));
