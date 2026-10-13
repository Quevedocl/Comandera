-- Fogón · migración 5: cobrar sin cerrar la mesa (la 2ª vuelta ya no suma lo que se pagó)
-- Ejecutar UNA vez en Supabase > SQL Editor (después de las migraciones anteriores). Es seguro repetirla.
-- Hazlo ANTES de subir los HTML nuevos.

-- 1) Cada pedido recuerda cuándo se cobró. null = pendiente de pago.
alter table orders add column if not exists paid_at timestamptz;

-- 2) Los pedidos de mesas ya cerradas (completed) se consideran cobrados
update orders set paid_at = coalesce(paid_at, created_at) where status::text = 'completed' and paid_at is null;

-- 3) La cuenta que ve el cliente ahora incluye paid_at (cambia el tipo de retorno: hay que recrearla)
drop function if exists table_account(uuid, uuid);
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

-- 4) Cobrar SIN cerrar la mesa: marca como pagados los pedidos hechos hasta p_upto (la hora de la llamada
--    del cliente), para no cobrar por error algo que pidió después de avisar. Atiende esa llamada.
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

-- 5) Cerrar mesa: igual que antes, y además deja como cobrado todo lo que faltaba
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

-- 6) Un pedido ya cobrado no se puede cancelar ni modificar desde el celular del cliente
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
  if o.status::text <> 'pending' or o.paid_at is not null then return 'not_pending'; end if;
  update orders set items = p_items, total = p_total, modified_at = now() where id = o.id;
  return 'ok';
end $$;
revoke all on function modify_order(uuid, uuid, jsonb, numeric) from public;
grant execute on function modify_order(uuid, uuid, jsonb, numeric) to anon, authenticated;
