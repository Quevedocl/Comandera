-- kepasa · esquema COMPLETO para una instalación nueva (incluye las migraciones 1 a 7)
-- Ejecutar UNA vez en Supabase > SQL Editor sobre un proyecto vacío.
-- Si ya tienes un proyecto funcionando, NO uses este archivo: ejecuta solo las migraciones que te falten (ver README.md).

-- ===== Tablas =====
create table if not exists restaurants (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null unique references auth.users on delete cascade,
  name text not null,
  slug text not null unique,
  logo_url text,
  active boolean not null default true,        -- lo maneja el administrador de la plataforma (suspender un local)
  open_now boolean not null default true,      -- lo maneja el dueño ("Abierto ahora" / "Local cerrado")
  tip_pct int not null default 10 check (tip_pct between 0 and 30),
  created_at timestamptz default now()
);
create table if not exists dining_tables (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants on delete cascade,
  name text not null,
  session_id uuid not null default gen_random_uuid(),   -- cambia al cerrar la mesa: el cliente anterior queda sin acceso
  released_sid uuid,
  created_at timestamptz default now()
);
create table if not exists products (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants on delete cascade,
  name text not null,
  category text not null,
  price numeric not null default 0 check (price >= 0),
  description text,
  image_url text,
  is_available boolean not null default true,
  created_at timestamptz default now()
);
create table if not exists product_addons (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants on delete cascade,
  name text not null,
  price numeric not null default 0 check (price >= 0),
  product_id text,
  category text,
  is_available boolean not null default true,
  created_at timestamptz default now(),
  check (product_id is not null or category is not null)
);
create table if not exists promotions (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants on delete cascade,
  title text not null,
  type text not null check (type in ('nxm','percent','price','info')),
  product_id text, buy_qty int, pay_qty int, value numeric, ends_on date,
  is_active boolean not null default true,
  created_at timestamptz default now()
);
create table if not exists orders (
  id uuid primary key default gen_random_uuid(),
  public_id uuid unique,
  restaurant_id uuid not null references restaurants on delete cascade,
  table_id uuid,
  table_name text check (table_name is null or char_length(table_name) <= 60),
  table_number int,
  session_id uuid,
  items jsonb not null default '[]'::jsonb,
  total numeric,
  status text not null default 'pending' check (status in ('pending','preparing','ready','completed','cancelled')),
  paid_at timestamptz,
  modified_at timestamptz,
  cancelled_at timestamptz,
  history jsonb not null default '[]'::jsonb,
  created_at timestamptz default now()
);
create table if not exists waiter_calls (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references restaurants on delete cascade,
  table_id uuid,
  table_name text not null,
  session_id uuid,
  reason text not null check (reason in ('pay','complaint','help')),
  note text check (note is null or char_length(note) <= 200),
  status text not null default 'open' check (status in ('open','done')),
  created_at timestamptz default now()
);
-- una sola llamada abierta por mesa y motivo (evita spam; el anónimo no puede leer la tabla, por eso lo garantiza un índice)
create unique index if not exists waiter_calls_open_key on waiter_calls (restaurant_id, table_name, reason) where status = 'open';
create table if not exists admins (email text primary key);

-- ===== Índices =====
create index if not exists orders_rest_status_idx on orders (restaurant_id, status, created_at);
create index if not exists orders_rest_created_idx on orders (restaurant_id, created_at desc);
create index if not exists orders_table_session_idx on orders (table_id, session_id);
create index if not exists products_rest_idx on products (restaurant_id, category);
create index if not exists promotions_rest_idx on promotions (restaurant_id);
create index if not exists dining_tables_rest_idx on dining_tables (restaurant_id);
create index if not exists product_addons_rest_idx on product_addons (restaurant_id);
create index if not exists waiter_calls_rest_idx on waiter_calls (restaurant_id, status);

-- ===== Permisos de columnas =====
-- el dueño solo puede crear su restaurante con nombre/slug/dueño y cambiar nombre, logo, propina y estado abierto/cerrado
revoke insert, update on restaurants from anon, authenticated;
grant insert (owner_id, name, slug) on restaurants to authenticated;
grant update (name, logo_url, tip_pct, open_now) on restaurants to authenticated;

-- ===== Seguridad (RLS) =====
create or replace function is_owner(rid uuid) returns boolean language sql security definer stable set search_path = public as
$$ select exists (select 1 from restaurants where id = rid and owner_id = auth.uid()) $$;

alter table restaurants enable row level security; alter table dining_tables enable row level security;
alter table promotions enable row level security; alter table products enable row level security;
alter table product_addons enable row level security; alter table orders enable row level security;
alter table waiter_calls enable row level security; alter table admins enable row level security;   -- admins: sin políticas, nadie la lee desde la web

drop policy if exists r_read on restaurants; drop policy if exists r_ins on restaurants; drop policy if exists r_upd on restaurants;
create policy r_read on restaurants for select using (true);
create policy r_ins on restaurants for insert to authenticated with check (owner_id = auth.uid());
create policy r_upd on restaurants for update to authenticated using (owner_id = auth.uid());

do $$ declare t text; begin foreach t in array array['products','dining_tables','promotions','product_addons'] loop
  execute format('drop policy if exists %1$s_read on %1$I', t);
  execute format('drop policy if exists %1$s_write on %1$I', t);
  execute format('create policy %1$s_read on %1$I for select using (true)', t);
  execute format('create policy %1$s_write on %1$I for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id))', t);
end loop; end $$;

-- el cliente (anónimo) solo puede crear pedidos nuevos y "pendientes", de un local activo y abierto, con la sesión vigente de su mesa
drop policy if exists o_ins on orders; drop policy if exists o_own on orders;
create policy o_ins on orders for insert to anon, authenticated with check (
  status = 'pending' and paid_at is null and restaurant_id is not null
  and exists (select 1 from restaurants r where r.id = restaurant_id and r.active and r.open_now)
  and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id and d.session_id = orders.session_id)));
create policy o_own on orders for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));

drop policy if exists wc_ins on waiter_calls; drop policy if exists wc_own on waiter_calls;
create policy wc_ins on waiter_calls for insert to anon, authenticated with check (
  status = 'open'
  and exists (select 1 from restaurants r where r.id = waiter_calls.restaurant_id and r.active)
  and (table_id is null or exists (select 1 from dining_tables d where d.id = waiter_calls.table_id and d.restaurant_id = waiter_calls.restaurant_id and d.session_id = waiter_calls.session_id)));
create policy wc_own on waiter_calls for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));

-- ===== Precios calculados en el servidor =====
create or replace function fogon_price_items(p_rid uuid, p_items jsonb, out o_items jsonb, out o_total numeric)
language plpgsql security definer stable set search_path = public as $$
declare
  it jsonb; ad jsonb; prod record; adr record; grp record; promo record;
  qty int; unit numeric; sub numeric := 0; disc numeric := 0; d numeric;
  lines jsonb := '[]'::jsonb; ads jsonb; ad_ids text[]; note text; titles jsonb := '{}'::jsonb;
  today date := (now() at time zone 'America/Santiago')::date;
begin
  if p_rid is null or p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 then
    raise exception 'pedido_invalido';
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(it) <> 'object' or coalesce(it->>'qty', '') !~ '^[0-9]{1,3}$' or coalesce(it->>'id', '') = '' then
      raise exception 'pedido_invalido';
    end if;
    qty := (it->>'qty')::int;
    if qty < 1 or qty > 20 then raise exception 'pedido_invalido'; end if;

    select p.* into prod from products p where p.restaurant_id = p_rid and p.id::text = it->>'id';
    if not found or prod.is_available is not true then raise exception 'pedido_invalido'; end if;

    unit := prod.price; ads := '[]'::jsonb; ad_ids := '{}';
    if jsonb_typeof(it->'addons') = 'array' then
      if jsonb_array_length(it->'addons') > 10 then raise exception 'pedido_invalido'; end if;
      for ad in select value from jsonb_array_elements(it->'addons') loop
        select a.* into adr from product_addons a
          where a.restaurant_id = p_rid and a.id::text = ad->>'id' and a.is_available
            and ((a.product_id is not null and a.product_id = prod.id::text) or (a.product_id is null and a.category = prod.category));
        if not found or adr.id::text = any (ad_ids) then raise exception 'pedido_invalido'; end if;
        ad_ids := ad_ids || adr.id::text;
        unit := unit + adr.price;
        ads := ads || jsonb_build_array(jsonb_build_object('id', adr.id, 'name', adr.name, 'price', adr.price));
      end loop;
    end if;

    note := nullif(left(btrim(coalesce(it->>'note', '')), 80), '');
    sub := sub + unit * qty;
    lines := lines || jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
      'id', prod.id::text, 'name', prod.name, 'qty', qty, 'price', prod.price,
      'note', note, 'addons', case when jsonb_array_length(ads) > 0 then ads end)));
  end loop;

  for grp in
    select l.id, sum(l.qty)::int as q, max(l.price) as pr
    from jsonb_to_recordset(lines) as l(id text, qty int, price numeric) group by l.id
  loop
    select x.* into promo from promotions x
      where x.restaurant_id = p_rid and x.is_active and x.type <> 'info' and x.product_id = grp.id
        and (x.ends_on is null or x.ends_on >= today)
      order by x.created_at limit 1;
    if not found then continue; end if;
    d := 0;
    if promo.type = 'nxm' and coalesce(promo.buy_qty, 0) > 0 and coalesce(promo.pay_qty, 0) >= 0 then
      d := floor(grp.q::numeric / promo.buy_qty) * greatest(promo.buy_qty - promo.pay_qty, 0) * grp.pr;
    elsif promo.type = 'percent' then
      d := round(grp.q * grp.pr * least(greatest(coalesce(promo.value, 0), 0), 100) / 100);
    elsif promo.type = 'price' then
      d := greatest(0, grp.pr - coalesce(promo.value, grp.pr)) * grp.q;
    end if;
    if d > 0 then disc := disc + d; titles := titles || jsonb_build_object(grp.id, promo.title); end if;
  end loop;

  if titles <> '{}'::jsonb then
    select jsonb_agg(case when titles ? (l.v->>'id') then l.v || jsonb_build_object('promo', titles->>(l.v->>'id')) else l.v end order by l.ord)
      into lines from jsonb_array_elements(lines) with ordinality as l(v, ord);
  end if;

  o_items := lines;
  o_total := greatest(sub - disc, 0);
end $$;
revoke all on function fogon_price_items(uuid, jsonb) from public, anon, authenticated;

create or replace function orders_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
  if (select count(*) from orders o
        where o.restaurant_id = new.restaurant_id and o.created_at > now() - interval '10 minutes'
          and ((new.table_id is not null and o.table_id = new.table_id) or (new.table_id is null and o.table_name is not distinct from new.table_name))) >= 40 then
    raise exception 'demasiados_pedidos';
  end if;
  select * into r from fogon_price_items(new.restaurant_id, new.items::jsonb);
  new.items := r.o_items;
  new.total := r.o_total;
  new.paid_at := null; new.modified_at := null; new.cancelled_at := null;
  new.history := '[]'::jsonb;
  if new.public_id is null then new.public_id := gen_random_uuid(); end if;
  return new;
end $$;
drop trigger if exists orders_before_insert on orders;
create trigger orders_before_insert before insert on orders for each row execute function orders_before_insert();

-- ===== Cuenta de la mesa y seguimiento (lo ve cualquier teléfono con la sesión vigente de la mesa) =====
create or replace function order_status(refs uuid[]) returns table (public_id uuid, status text) language sql security definer stable set search_path = public as
$$ select o.public_id, o.status::text from orders o where o.public_id = any(refs) $$;
grant execute on function order_status(uuid[]) to anon, authenticated;

create or replace function table_account(p_table uuid, p_session uuid)
returns table (public_id uuid, status text, items jsonb, total numeric, created_at timestamptz, modified_at timestamptz, paid_at timestamptz)
language sql security definer stable set search_path = public as $$
  select o.public_id, o.status::text, o.items::jsonb, o.total, o.created_at, o.modified_at, o.paid_at
  from orders o join dining_tables d on d.id = o.table_id
  where o.table_id = p_table and d.session_id = p_session and o.session_id = p_session and o.public_id is not null
  order by o.created_at
$$;
revoke all on function table_account(uuid, uuid) from public;
grant execute on function table_account(uuid, uuid) to anon, authenticated;

-- ===== Cancelar / modificar pedido (solo mientras está "pending", sin cobrar y con la sesión vigente de la mesa) =====
create or replace function cancel_order(p_public uuid, p_session uuid) returns text
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from orders where public_id = p_public for update;
  if not found then return 'not_found'; end if;
  if o.session_id is distinct from p_session
     or not exists (select 1 from dining_tables d where d.id = o.table_id and d.session_id = p_session) then return 'locked'; end if;
  if o.status::text = 'cancelled' then return 'cancelled'; end if;
  if o.status::text <> 'pending' or o.paid_at is not null then return 'not_pending'; end if;
  update orders set status = 'cancelled', cancelled_at = now() where id = o.id;
  return 'ok';
end $$;
revoke all on function cancel_order(uuid, uuid) from public;
grant execute on function cancel_order(uuid, uuid) to anon, authenticated;

create or replace function modify_order(p_public uuid, p_session uuid, p_items jsonb, p_total numeric) returns text
language plpgsql security definer set search_path = public as $$
declare o record; r record;
begin
  select * into o from orders where public_id = p_public for update;
  if not found then return 'not_found'; end if;
  if o.session_id is distinct from p_session
     or not exists (select 1 from dining_tables d where d.id = o.table_id and d.session_id = p_session) then return 'locked'; end if;
  if o.status::text = 'cancelled' then return 'cancelled'; end if;
  if o.status::text <> 'pending' or o.paid_at is not null then return 'not_pending'; end if;
  begin
    select * into r from fogon_price_items(o.restaurant_id, p_items);
  exception when raise_exception then
    return 'invalid';
  end;
  update orders
    set history = history || jsonb_build_array(jsonb_build_object('at', now(), 'items', o.items::jsonb, 'total', o.total)),
        items = r.o_items, total = r.o_total, modified_at = now()
    where id = o.id;
  return 'ok';
end $$;
revoke all on function modify_order(uuid, uuid, jsonb, numeric) from public;
grant execute on function modify_order(uuid, uuid, jsonb, numeric) to anon, authenticated;

-- ===== Mesero: registrar el cobro (sin cerrar la mesa) y cerrar / liberar mesa =====
create or replace function charge_table(p_restaurant uuid, p_table uuid, p_table_name text, p_upto timestamptz default now(), p_call uuid default null) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_owner(p_restaurant) then raise exception 'no autorizado'; end if;
  update orders set paid_at = now()
    where restaurant_id = p_restaurant and paid_at is null and status::text <> 'cancelled' and created_at <= p_upto
      and ((p_table is not null and table_id = p_table) or (table_id is null and coalesce(table_name, 'Mesa ' || table_number) = p_table_name));
  if p_call is not null then
    update waiter_calls set status = 'done' where id = p_call and restaurant_id = p_restaurant;
  end if;
end $$;
revoke all on function charge_table(uuid, uuid, text, timestamptz, uuid) from public, anon;
grant execute on function charge_table(uuid, uuid, text, timestamptz, uuid) to authenticated;

create or replace function close_table(p_restaurant uuid, p_table uuid, p_table_name text, p_release boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare ns uuid := gen_random_uuid();
begin
  if not is_owner(p_restaurant) then raise exception 'no autorizado'; end if;
  update orders set status = 'completed', paid_at = coalesce(paid_at, now())
    where restaurant_id = p_restaurant and status::text not in ('completed', 'cancelled')
      and ((p_table is not null and table_id = p_table) or (table_id is null and coalesce(table_name, 'Mesa ' || table_number) = p_table_name));
  if p_table is not null then
    update dining_tables set session_id = ns, released_sid = case when p_release then ns else released_sid end
      where id = p_table and restaurant_id = p_restaurant;
  end if;
  update waiter_calls set status = 'done'
    where restaurant_id = p_restaurant and status = 'open' and (table_id = p_table or table_name = p_table_name);
end $$;
revoke all on function close_table(uuid, uuid, text, boolean) from public, anon;
grant execute on function close_table(uuid, uuid, text, boolean) to authenticated;

-- ===== Administrador de la plataforma =====
-- Después de crear tu cuenta en la app, agrégate como administrador (cambia el correo):
--   insert into admins (email) values ('tu-correo@ejemplo.com') on conflict do nothing;
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
      (select count(*) from orders o where o.restaurant_id = r.id and o.status::text <> 'cancelled'),
      (select count(*) from orders o where o.restaurant_id = r.id and o.status::text <> 'cancelled' and (o.created_at at time zone 'America/Santiago')::date = (now() at time zone 'America/Santiago')::date),
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

-- ===== Tiempo real =====
do $$ declare t text; begin foreach t in array array['orders','products','promotions','dining_tables','waiter_calls','product_addons'] loop
  begin execute format('alter publication supabase_realtime add table %I', t); exception when others then null; end;
end loop; end $$;

-- ===== Almacenamiento: fotos de productos y logos (públicos para mostrarse; cada dueño solo escribe en su carpeta) =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('products', 'products', true, 5242880, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['image/png','image/jpeg','image/webp'];
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('logos', 'logos', true, 2097152, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set file_size_limit = 2097152, allowed_mime_types = array['image/png','image/jpeg','image/webp'];

drop policy if exists products_upload on storage.objects;   -- nombre antiguo de la política de subida
do $$ declare b text; begin foreach b in array array['products','logos'] loop
  execute format('drop policy if exists %1$s_ins on storage.objects', b);
  execute format('drop policy if exists %1$s_del on storage.objects', b);
  execute format($f$create policy %1$s_ins on storage.objects for insert to authenticated with check (bucket_id = %1$L and exists (select 1 from public.restaurants r where r.owner_id = auth.uid() and r.id::text = (storage.foldername(objects.name))[1]))$f$, b);
  execute format($f$create policy %1$s_del on storage.objects for delete to authenticated using (bucket_id = %1$L and exists (select 1 from public.restaurants r where r.owner_id = auth.uid() and r.id::text = (storage.foldername(objects.name))[1]))$f$, b);
end loop; end $$;
-- kepasa · migración 8 · sesión de mesa PRIVADA, pedidos solo desde una mesa válida y scan-menu con cupo
-- Ejecutar en SQL Editor (repetible) ANTES de subir el carta.html nuevo. Las mesas y QR existentes siguen funcionando.

-- 1) Las mesas (y su session_id) ya no las puede leer cualquiera: solo su dueño.
drop policy if exists dining_tables_read on dining_tables;
drop policy if exists dining_tables_write on dining_tables;
drop policy if exists dining_tables_own on dining_tables;
create policy dining_tables_own on dining_tables for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));
revoke all on dining_tables from anon;

-- 2) El cliente entra a su mesa por RPC. El id de la mesa (uuid del QR, imposible de adivinar) hace de llave.
create or replace function join_table(p_restaurant uuid, p_table uuid)
returns table (id uuid, name text, session_id uuid, released_sid uuid)
language sql security definer stable set search_path = public as $$
  select d.id, d.name, d.session_id, d.released_sid from dining_tables d where d.id = p_table and d.restaurant_id = p_restaurant
$$;
revoke all on function join_table(uuid, uuid) from public;
grant execute on function join_table(uuid, uuid) to anon, authenticated;

create or replace function table_session_ok(p_rid uuid, p_table uuid, p_session uuid) returns boolean
language sql security definer stable set search_path = public as $$
  select p_table is not null and p_session is not null
    and exists (select 1 from dining_tables d where d.id = p_table and d.restaurant_id = p_rid and d.session_id = p_session)
$$;
revoke all on function table_session_ok(uuid, uuid, uuid) from public;
grant execute on function table_session_ok(uuid, uuid, uuid) to anon, authenticated;

-- 3) Pedir y llamar al mesero SOLO con mesa y sesión vigentes (ya no existe el camino "sin mesa" para el anónimo).
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert to anon, authenticated with check (
  status = 'pending' and paid_at is null and restaurant_id is not null
  and exists (select 1 from restaurants r where r.id = restaurant_id and r.active and r.open_now)
  and table_session_ok(restaurant_id, table_id, session_id));
drop policy if exists wc_ins on waiter_calls;
create policy wc_ins on waiter_calls for insert to anon, authenticated with check (
  status = 'open'
  and exists (select 1 from restaurants r where r.id = waiter_calls.restaurant_id and r.active)
  and table_session_ok(waiter_calls.restaurant_id, waiter_calls.table_id, waiter_calls.session_id));

-- 4) El nombre de la mesa lo pone el servidor (no el teléfono) y el tope anti-spam es por mesa Y por local.
create or replace function orders_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare r record; tname text;
begin
  if new.table_id is not null then
    select d.name into tname from dining_tables d where d.id = new.table_id and d.restaurant_id = new.restaurant_id;
    if tname is null then raise exception 'mesa_invalida'; end if;
    new.table_name := tname;
    if (select count(*) from orders o where o.table_id = new.table_id and o.created_at > now() - interval '10 minutes') >= 40 then
      raise exception 'demasiados_pedidos';
    end if;
  end if;
  if (select count(*) from orders o where o.restaurant_id = new.restaurant_id and o.created_at > now() - interval '10 minutes') >= 200 then
    raise exception 'demasiados_pedidos';
  end if;
  select * into r from fogon_price_items(new.restaurant_id, new.items::jsonb);
  new.items := r.o_items; new.total := r.o_total;
  new.paid_at := null; new.modified_at := null; new.cancelled_at := null; new.history := '[]'::jsonb;
  if new.public_id is null then new.public_id := gen_random_uuid(); end if;
  return new;
end $$;
drop trigger if exists orders_before_insert on orders;
create trigger orders_before_insert before insert on orders for each row execute function orders_before_insert();

create or replace function waiter_calls_before_insert() returns trigger language plpgsql security definer set search_path = public as $$
declare tname text;
begin
  if new.table_id is not null then
    select d.name into tname from dining_tables d where d.id = new.table_id and d.restaurant_id = new.restaurant_id;
    if tname is null then raise exception 'mesa_invalida'; end if;
    new.table_name := tname;
  end if;
  return new;
end $$;
drop trigger if exists waiter_calls_before_insert on waiter_calls;
create trigger waiter_calls_before_insert before insert on waiter_calls for each row execute function waiter_calls_before_insert();

-- 5) El anónimo ya no ve el owner_id de los restaurantes (solo lo necesario para mostrar la carta).
revoke select on restaurants from anon;
grant select (id, name, slug, logo_url, active, open_now, tip_pct, created_at) on restaurants to anon;

-- 6) Cupo diario para la función scan-menu (15 escaneos por dueño al día) — evita gastar la cuota de IA.
create table if not exists scan_usage (user_id uuid not null, day date not null default current_date, n int not null default 0, primary key (user_id, day));
alter table scan_usage enable row level security;
revoke all on scan_usage from anon, authenticated;
create or replace function use_scan_quota() returns boolean language plpgsql security definer set search_path = public as $$
declare c int;
begin
  if auth.uid() is null or not exists (select 1 from restaurants where owner_id = auth.uid()) then return false; end if;
  insert into scan_usage as s (user_id, day, n) values (auth.uid(), current_date, 1)
    on conflict (user_id, day) do update set n = s.n + 1 returning s.n into c;
  return c <= 15;
end $$;
revoke all on function use_scan_quota() from public, anon;
grant execute on function use_scan_quota() to authenticated;
