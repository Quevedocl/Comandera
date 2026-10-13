-- Comandera · migración 4: agregados con precio, vista previa, cancelar/modificar pedidos,
-- seguimiento del pedido, cuenta compartida/dividida y propina sugerida.
-- Ejecutar UNA vez en Supabase > SQL Editor (después de las migraciones anteriores). Es seguro repetirla.
-- Hazlo ANTES de subir los HTML nuevos.

-- 1) Productos: descripción para la vista previa de la comida
alter table products add column if not exists description text;

-- 2) Propina sugerida por restaurante (0 = sin sugerencia). El dueño la cambia en Configuración.
alter table restaurants add column if not exists tip_pct int not null default 10;
do $$ begin
  alter table restaurants add constraint restaurants_tip_pct_check check (tip_pct between 0 and 30);
exception when duplicate_object then null; end $$;
grant update (name, logo_url, tip_pct) on restaurants to authenticated;

-- 3) Pedidos: estado "cancelled", marca de modificación y seguimiento por public_id
alter table orders add column if not exists public_id uuid;
create unique index if not exists orders_public_id_key on orders (public_id);
alter table orders add column if not exists modified_at timestamptz;
alter table orders add column if not exists cancelled_at timestamptz;

do $$ declare c record; udt text; begin
  select udt_name into udt from information_schema.columns where table_schema = 'public' and table_name = 'orders' and column_name = 'status';
  if udt not in ('text', 'varchar', 'bpchar') then
    -- la columna es un ENUM: se le agrega el valor nuevo
    execute format('alter type %I add value if not exists %L', udt, 'cancelled');
  else
    -- si existía un CHECK sobre status, se reemplaza por uno que incluye "cancelled"
    for c in select conname from pg_constraint where conrelid = 'public.orders'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%status%' loop
      execute format('alter table orders drop constraint %I', c.conname);
    end loop;
    alter table orders add constraint orders_status_check check (status in ('pending','preparing','ready','completed','cancelled')) not valid;
  end if;
end $$;

-- 4) Agregados con precio (ej. "Queso extra +$1.000"). Aplican a un producto o a toda una categoría.
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
alter table product_addons enable row level security;
drop policy if exists product_addons_read on product_addons;
drop policy if exists product_addons_write on product_addons;
create policy product_addons_read on product_addons for select using (true);
create policy product_addons_write on product_addons for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));
do $$ begin alter publication supabase_realtime add table product_addons; exception when others then null; end $$;

-- 5) Cuenta de la mesa + seguimiento en vivo (lo ve cualquier teléfono con la sesión vigente de la mesa)
create or replace function table_account(p_table uuid, p_session uuid)
returns table (public_id uuid, status text, items jsonb, total numeric, created_at timestamptz, modified_at timestamptz)
language sql security definer stable set search_path = public as $$
  select o.public_id, o.status::text, o.items::jsonb, o.total, o.created_at, o.modified_at
  from orders o join dining_tables d on d.id = o.table_id
  where o.table_id = p_table and d.session_id = p_session and o.session_id = p_session and o.public_id is not null
  order by o.created_at
$$;
revoke all on function table_account(uuid, uuid) from public;
grant execute on function table_account(uuid, uuid) to anon, authenticated;

-- 6) Cancelar un pedido (solo mientras está "pending" y con la sesión vigente de la mesa)
create or replace function cancel_order(p_public uuid, p_session uuid) returns text
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from orders where public_id = p_public for update;
  if not found then return 'not_found'; end if;
  if o.session_id is distinct from p_session
     or not exists (select 1 from dining_tables d where d.id = o.table_id and d.session_id = p_session) then return 'locked'; end if;
  if o.status::text = 'cancelled' then return 'cancelled'; end if;
  if o.status::text <> 'pending' then return 'not_pending'; end if;
  update orders set status = 'cancelled', cancelled_at = now() where id = o.id;
  return 'ok';
end $$;
revoke all on function cancel_order(uuid, uuid) from public;
grant execute on function cancel_order(uuid, uuid) to anon, authenticated;

-- 7) Modificar un pedido (solo mientras está "pending"). La cocina ve la marca "Modificado".
create or replace function modify_order(p_public uuid, p_session uuid, p_items jsonb, p_total numeric) returns text
language plpgsql security definer set search_path = public as $$
declare o record;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 or jsonb_array_length(p_items) > 60 or p_total is null or p_total < 0 then
    return 'invalid';
  end if;
  select * into o from orders where public_id = p_public for update;
  if not found then return 'not_found'; end if;
  if o.session_id is distinct from p_session
     or not exists (select 1 from dining_tables d where d.id = o.table_id and d.session_id = p_session) then return 'locked'; end if;
  if o.status::text = 'cancelled' then return 'cancelled'; end if;
  if o.status::text <> 'pending' then return 'not_pending'; end if;
  update orders set items = p_items, total = p_total, modified_at = now() where id = o.id;
  return 'ok';
end $$;
revoke all on function modify_order(uuid, uuid, jsonb, numeric) from public;
grant execute on function modify_order(uuid, uuid, jsonb, numeric) to anon, authenticated;

-- 8) Cerrar mesa: igual que antes, pero los pedidos cancelados NO se pasan a "completed" (no cuentan como ingreso)
create or replace function close_table(p_restaurant uuid, p_table uuid, p_table_name text, p_release boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare ns uuid := gen_random_uuid();
begin
  if not is_owner(p_restaurant) then raise exception 'no autorizado'; end if;
  update orders set status = 'completed'
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

-- 9) Panel de administrador: los pedidos cancelados no cuentan
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
