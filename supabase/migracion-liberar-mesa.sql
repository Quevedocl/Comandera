-- Comandera · migración 2: "Liberar mesa" distinto de "Cobrar y cerrar mesa"
-- Ejecutar UNA vez en Supabase > SQL Editor (después de migracion-sesion-mesa.sql). Es seguro repetirla.
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
