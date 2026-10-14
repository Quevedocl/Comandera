-- kepasa · migración 9 · pantalla de cocina (acceso solo para personal, sin cobros ni carta ni ingresos)
-- Ejecutar en SQL Editor (repetible) ANTES de subir cocina.html y el index.html nuevo.

-- Llave secreta por local (solo la lee su dueño). Quien tenga el enlace de cocina ve pedidos activos y los marca preparando/listo; nada más.
create table if not exists kitchen_access (restaurant_id uuid primary key references restaurants on delete cascade, key uuid not null unique default gen_random_uuid());
alter table kitchen_access enable row level security;
revoke all on kitchen_access from anon;
drop policy if exists ka_own on kitchen_access;
create policy ka_own on kitchen_access for all to authenticated using (is_owner(restaurant_id)) with check (is_owner(restaurant_id));
insert into kitchen_access (restaurant_id) select id from restaurants on conflict do nothing;
create or replace function restaurants_kitchen_row() returns trigger language plpgsql security definer set search_path = public as $$
begin insert into kitchen_access (restaurant_id) values (new.id) on conflict do nothing; return new; end $$;
drop trigger if exists restaurants_kitchen_row on restaurants;
create trigger restaurants_kitchen_row after insert on restaurants for each row execute function restaurants_kitchen_row();

-- Nombre del local si la llave es válida y el local está activo (null si no).
create or replace function kitchen_info(p_key uuid) returns text language sql security definer stable set search_path = public as $$
  select r.name from kitchen_access k join restaurants r on r.id = k.restaurant_id where k.key = p_key and r.active
$$;

-- Pedidos para cocina: SIN precios ni totales. Activos (12 h), listos (2 h) y cancelados recientes (10 min, para no cocinarlos).
create or replace function kitchen_orders(p_key uuid)
returns table (id uuid, table_name text, status text, created_at timestamptz, modified_at timestamptz, cancelled_at timestamptz, items jsonb)
language sql security definer stable set search_path = public as $$
  select o.id, coalesce(o.table_name, 'Mesa ' || o.table_number), o.status::text, o.created_at, o.modified_at, o.cancelled_at,
    (select coalesce(jsonb_agg(jsonb_build_object('name', i->>'name', 'qty', i->'qty', 'note', i->>'note', 'promo', i->>'promo',
        'addons', (select coalesce(jsonb_agg(a->>'name'), '[]'::jsonb) from jsonb_array_elements(coalesce(i->'addons', '[]'::jsonb)) a))), '[]'::jsonb)
       from jsonb_array_elements(o.items::jsonb) i)
  from kitchen_access k join restaurants r on r.id = k.restaurant_id join orders o on o.restaurant_id = r.id
  where k.key = p_key and r.active and (
       (o.status::text in ('pending', 'preparing') and o.created_at > now() - interval '12 hours')
    or (o.status::text = 'ready' and o.created_at > now() - interval '2 hours')
    or (o.status::text = 'cancelled' and o.cancelled_at > now() - interval '10 minutes'))
  order by o.created_at
$$;

-- Cocina solo puede avanzar/retroceder el estado de preparación (nunca cobrar, cerrar mesa ni cancelar).
create or replace function kitchen_set_status(p_key uuid, p_order uuid, p_status text) returns text language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select x.* into o from orders x join kitchen_access k on k.restaurant_id = x.restaurant_id join restaurants r on r.id = x.restaurant_id
    where k.key = p_key and r.active and x.id = p_order for update of x;
  if not found then return 'not_found'; end if;
  if o.status::text in ('completed', 'cancelled') then return 'closed'; end if;
  if (o.status::text, p_status) not in (('pending', 'preparing'), ('preparing', 'ready'), ('ready', 'preparing'), ('preparing', 'pending')) then return 'invalid'; end if;
  update orders set status = p_status where id = o.id;
  return 'ok';
end $$;

revoke all on function kitchen_info(uuid), kitchen_orders(uuid), kitchen_set_status(uuid, uuid, text) from public;
grant execute on function kitchen_info(uuid), kitchen_orders(uuid), kitchen_set_status(uuid, uuid, text) to anon, authenticated;
