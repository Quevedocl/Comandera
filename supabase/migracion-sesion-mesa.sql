-- Fogón · migración: llamar al mesero + mesa cerrada = cliente anterior sin acceso
-- Ejecutar UNA vez en Supabase > SQL Editor (es seguro repetirla). Hazlo ANTES de subir los HTML nuevos.

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
