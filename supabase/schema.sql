-- Comandera multi-restaurante · ejecutar UNA vez en Supabase > SQL Editor
-- tabla promotions antigua (otra estructura, vacía): se renombra, no se borra
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='promotions' and column_name='product_ids') then
    alter table promotions rename to promotions_old;
    alter index if exists promotions_pkey rename to promotions_old_pkey;
  end if;
end $$;
create table if not exists restaurants (id uuid primary key default gen_random_uuid(), owner_id uuid not null unique references auth.users on delete cascade, name text not null, slug text not null unique, created_at timestamptz default now());
create table if not exists dining_tables (id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references restaurants on delete cascade, name text not null, created_at timestamptz default now());
create table if not exists promotions (id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references restaurants on delete cascade, title text not null, type text not null check (type in ('nxm','percent','price','info')), product_id text, buy_qty int, pay_qty int, value numeric, ends_on date, is_active boolean not null default true, created_at timestamptz default now());
alter table products add column if not exists restaurant_id uuid references restaurants on delete cascade;
alter table orders add column if not exists restaurant_id uuid references restaurants on delete cascade, add column if not exists table_id uuid, add column if not exists table_name text, add column if not exists total numeric;
alter table orders alter column table_number drop not null;

create or replace function is_owner(rid uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists (select 1 from restaurants where id = rid and owner_id = auth.uid()) $$;

-- reemplaza las políticas antiguas
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies where schemaname='public' and tablename in ('products','orders') loop
    execute format('drop policy %I on %I', p.policyname, p.tablename); end loop; end $$;
alter table restaurants enable row level security; alter table dining_tables enable row level security;
alter table promotions enable row level security; alter table products enable row level security; alter table orders enable row level security;

create policy r_read on restaurants for select using (true);
create policy r_ins on restaurants for insert to authenticated with check (owner_id = auth.uid());
create policy r_upd on restaurants for update to authenticated using (owner_id = auth.uid());
do $$ declare t text; begin foreach t in array array['products','dining_tables','promotions'] loop
  execute format('create policy %1$s_read on %1$I for select using (true)', t);
  execute format('create policy %1$s_write on %1$I for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id))', t);
end loop; end $$;
create policy o_ins on orders for insert to anon, authenticated with check (restaurant_id is not null and exists (select 1 from restaurants where id = restaurant_id) and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id)));
create policy o_own on orders for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));

do $$ declare t text; begin foreach t in array array['orders','products','promotions','dining_tables'] loop
  begin execute format('alter publication supabase_realtime add table %I', t); exception when others then null; end;
end loop; end $$;

insert into storage.buckets (id, name, public) values ('products','products',true) on conflict (id) do nothing;
create policy products_upload on storage.objects for insert to authenticated with check (bucket_id='products' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));

-- Productos que ya tenías (sin restaurante): crea tu cuenta en la app y luego corre:
-- update products set restaurant_id = (select id from restaurants where name = 'TU RESTAURANTE') where restaurant_id is null;

-- ===== seguimiento de pedido y llamada al mesero =====
alter table orders add column if not exists public_id uuid;
create unique index if not exists orders_public_id_key on orders (public_id);
create or replace function order_status(refs uuid[]) returns table (public_id uuid, status text) language sql security definer stable set search_path = public as
$$ select o.public_id, o.status from orders o where o.public_id = any(refs) $$;
grant execute on function order_status(uuid[]) to anon, authenticated;
create table if not exists waiter_calls (id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references restaurants on delete cascade, table_id uuid, table_name text not null, reason text not null check (reason in ('pay','complaint','help')), note text, status text not null default 'open' check (status in ('open','done')), created_at timestamptz default now());
alter table waiter_calls enable row level security;
create policy wc_ins on waiter_calls for insert to anon, authenticated with check (exists (select 1 from restaurants r where r.id = waiter_calls.restaurant_id) and (table_id is null or exists (select 1 from dining_tables d where d.id = waiter_calls.table_id and d.restaurant_id = waiter_calls.restaurant_id)) and not exists (select 1 from waiter_calls w where w.restaurant_id = waiter_calls.restaurant_id and w.table_name = waiter_calls.table_name and w.reason = waiter_calls.reason and w.status = 'open'));
create policy wc_own on waiter_calls for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));
do $$ begin alter publication supabase_realtime add table waiter_calls; exception when others then null; end $$;

-- ===== sesión de mesa + cierre seguro (ver supabase/migracion-sesion-mesa.sql; ejecútala también en instalaciones nuevas) =====

-- 1) Cada mesa tiene una "sesión". Al cerrar/cobrar la mesa la sesión cambia y el QR/pantalla del cliente anterior deja de servir.
alter table dining_tables add column if not exists session_id uuid not null default gen_random_uuid();
alter table orders add column if not exists session_id uuid;

-- 2) Llamadas al mesero (se crea si no existía)
create table if not exists waiter_calls (id uuid primary key default gen_random_uuid(), restaurant_id uuid not null references restaurants on delete cascade, table_id uuid, table_name text not null, reason text not null check (reason in ('pay','complaint','help')), note text, status text not null default 'open' check (status in ('open','done')), created_at timestamptz default now());
alter table waiter_calls add column if not exists session_id uuid;
alter table waiter_calls enable row level security;

-- una sola llamada abierta por mesa y motivo (evita spam; el anónimo no puede leer la tabla, por eso lo garantiza un índice)
update waiter_calls set status = 'done' where status = 'open' and id not in (select distinct on (restaurant_id, table_name, reason) id from waiter_calls where status = 'open' order by restaurant_id, table_name, reason, created_at);
create unique index if not exists waiter_calls_open_key on waiter_calls (restaurant_id, table_name, reason) where status = 'open';

-- 3) Políticas: el cliente solo puede pedir/llamar con la sesión vigente de su mesa
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert to anon, authenticated with check (status = 'pending' and restaurant_id is not null and exists (select 1 from restaurants where id = restaurant_id) and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id and d.session_id = orders.session_id)));
drop policy if exists wc_ins on waiter_calls;
create policy wc_ins on waiter_calls for insert to anon, authenticated with check (status = 'open' and exists (select 1 from restaurants r where r.id = waiter_calls.restaurant_id) and (table_id is null or exists (select 1 from dining_tables d where d.id = waiter_calls.table_id and d.restaurant_id = waiter_calls.restaurant_id and d.session_id = waiter_calls.session_id)));
drop policy if exists wc_own on waiter_calls;
create policy wc_own on waiter_calls for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));
do $$ begin alter publication supabase_realtime add table waiter_calls; exception when others then null; end $$;

-- 4) Cerrar mesa: completa todos sus pedidos, atiende sus llamadas y cambia la sesión (atómico)
create or replace function close_table(p_restaurant uuid, p_table uuid, p_table_name text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner(p_restaurant) then raise exception 'no autorizado'; end if;
  update orders set status = 'completed'
    where restaurant_id = p_restaurant and status <> 'completed'
      and ((p_table is not null and table_id = p_table) or (table_id is null and coalesce(table_name, 'Mesa ' || table_number) = p_table_name));
  if p_table is not null then
    update dining_tables set session_id = gen_random_uuid() where id = p_table and restaurant_id = p_restaurant;
  end if;
  update waiter_calls set status = 'done'
    where restaurant_id = p_restaurant and status = 'open' and (table_id = p_table or table_name = p_table_name);
end $$;
revoke all on function close_table(uuid, uuid, text) from public, anon;
grant execute on function close_table(uuid, uuid, text) to authenticated;
alter table dining_tables add column if not exists released_sid uuid;

drop function if exists close_table(uuid, uuid, text);
create or replace function close_table(p_restaurant uuid, p_table uuid, p_table_name text, p_release boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare ns uuid := gen_random_uuid();
begin
  if not is_owner(p_restaurant) then raise exception 'no autorizado'; end if;
  update orders set status = 'completed'
    where restaurant_id = p_restaurant and status <> 'completed'
      and ((p_table is not null and table_id = p_table) or (table_id is null and coalesce(table_name, 'Mesa ' || table_number) = p_table_name));
  if p_table is not null then
    -- cerrar: sesión nueva (el teléfono anterior queda bloqueado). liberar: además la marca como "reabierta por el mesero"
    update dining_tables set session_id = ns, released_sid = case when p_release then ns else released_sid end
      where id = p_table and restaurant_id = p_restaurant;
  end if;
  update waiter_calls set status = 'done'
    where restaurant_id = p_restaurant and status = 'open' and (table_id = p_table or table_name = p_table_name);
end $$;
revoke all on function close_table(uuid, uuid, text, boolean) from public, anon;
grant execute on function close_table(uuid, uuid, text, boolean) to authenticated;

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

-- ===== Mejoras (agregados, cancelar/modificar, cuenta dividida, propina): ejecuta también supabase/migracion-mejoras.sql =====
