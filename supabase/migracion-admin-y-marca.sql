-- Comandera · migración 3: panel de administrador, logo/nombre del negocio y suspensión de locales
-- Ejecutar UNA vez en Supabase > SQL Editor (después de las migraciones anteriores). Es seguro repetirla.

-- 1) Marca del negocio y estado
alter table restaurants add column if not exists logo_url text;
alter table restaurants add column if not exists active boolean not null default true;

-- el dueño solo puede cambiar nombre y logo (no el estado, el slug ni el dueño)
revoke update on restaurants from anon, authenticated;
grant update (name, logo_url) on restaurants to authenticated;

-- 2) Administradores
create table if not exists admins (email text primary key);
alter table admins enable row level security;            -- sin políticas: nadie la lee desde la web
insert into admins (email) values ('quevedotroncoso@icloud.com') on conflict do nothing;

create or replace function is_admin() returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from auth.users u join admins a on lower(a.email) = lower(u.email) where u.id = auth.uid() and u.email_confirmed_at is not null)
$$;
revoke all on function is_admin() from public, anon;
grant execute on function is_admin() to authenticated;

create or replace function admin_overview() returns table (id uuid, name text, slug text, owner_email text, created_at timestamptz, active boolean, logo_url text, tables_count bigint, products_count bigint, orders_total bigint, orders_today bigint, last_order_at timestamptz, open_calls bigint)
language plpgsql security definer stable set search_path = public as $$
begin
  if not is_admin() then raise exception 'no autorizado'; end if;
  return query
    select r.id, r.name, r.slug, u.email::text, r.created_at, r.active, r.logo_url,
      (select count(*) from dining_tables d where d.restaurant_id = r.id),
      (select count(*) from products p where p.restaurant_id = r.id),
      (select count(*) from orders o where o.restaurant_id = r.id),
      (select count(*) from orders o where o.restaurant_id = r.id and (o.created_at at time zone 'America/Santiago')::date = (now() at time zone 'America/Santiago')::date),
      (select max(o.created_at) from orders o where o.restaurant_id = r.id),
      (select count(*) from waiter_calls w where w.restaurant_id = r.id and w.status = 'open')
    from restaurants r left join auth.users u on u.id = r.owner_id
    order by r.created_at desc;
end $$;
revoke all on function admin_overview() from public, anon;
grant execute on function admin_overview() to authenticated;

create or replace function admin_set_active(p_id uuid, p_active boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'no autorizado'; end if;
  update restaurants set active = p_active where id = p_id;
end $$;
revoke all on function admin_set_active(uuid, boolean) from public, anon;
grant execute on function admin_set_active(uuid, boolean) to authenticated;

-- 3) Un local suspendido no recibe pedidos ni llamadas
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert to anon, authenticated with check (status = 'pending' and restaurant_id is not null and exists (select 1 from restaurants r where r.id = restaurant_id and r.active) and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id and d.session_id = orders.session_id)));
drop policy if exists wc_ins on waiter_calls;
create policy wc_ins on waiter_calls for insert to anon, authenticated with check (status = 'open' and exists (select 1 from restaurants r where r.id = waiter_calls.restaurant_id and r.active) and (table_id is null or exists (select 1 from dining_tables d where d.id = waiter_calls.table_id and d.restaurant_id = waiter_calls.restaurant_id and d.session_id = waiter_calls.session_id)));

-- 4) Almacenamiento de logos (público para mostrarlos; cada dueño solo escribe en su carpeta)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values ('logos', 'logos', true, 2097152, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set file_size_limit = 2097152, allowed_mime_types = array['image/png','image/jpeg','image/webp'];
drop policy if exists logos_ins on storage.objects;
create policy logos_ins on storage.objects for insert to authenticated with check (bucket_id = 'logos' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));
drop policy if exists logos_del on storage.objects;
create policy logos_del on storage.objects for delete to authenticated using (bucket_id = 'logos' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));
