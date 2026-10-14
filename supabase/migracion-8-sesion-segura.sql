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
