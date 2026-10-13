-- ALTiro · migración 7: seguridad y robustez
--   · el total y los precios de cada pedido se calculan en el SERVIDOR (el celular del cliente ya no puede mandar precios inventados)
--   · tope de pedidos por mesa (anti-spam), un pedido nuevo nunca nace "pagado"
--   · índices para que el panel siga rápido con muchos pedidos
--   · almacenamiento de fotos de productos (límite de peso y tipo, y permiso para borrar)
--   · historial de modificaciones de cada pedido
-- Ejecutar UNA vez en Supabase > SQL Editor (después de las migraciones 1 a 6). Es seguro repetirla.
-- Hazlo ANTES de subir los HTML nuevos.

-- 1) Historial: cada vez que el cliente modifica un pedido se guarda la versión anterior
alter table orders add column if not exists history jsonb not null default '[]'::jsonb;

-- 2) Calcula items y total reales a partir de los precios vigentes en la base de datos.
--    Misma lógica de promociones que la carta (N×M, % de descuento, precio especial).
--    Lanza 'pedido_invalido' si algo no cuadra (producto inexistente o agotado, cantidad fuera de rango, agregado que no corresponde).
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

  -- descuentos: la promoción mira la cantidad total del producto aunque esté repartida en varias líneas
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

-- 3) Todo pedido nuevo pasa por aquí: precios reales, sin marcas de pago y con tope anti-spam
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

-- 4) La política de inserción ya no admite pedidos "pagados"
drop policy if exists o_ins on orders;
create policy o_ins on orders for insert to anon, authenticated with check (
  status = 'pending' and paid_at is null and restaurant_id is not null
  and exists (select 1 from restaurants r where r.id = restaurant_id and r.active and r.open_now)
  and (table_id is null or exists (select 1 from dining_tables d where d.id = table_id and d.restaurant_id = orders.restaurant_id and d.session_id = orders.session_id)));

-- 5) Modificar pedido: también recalcula en el servidor (p_total se ignora) y guarda la versión anterior
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

-- 6) Un restaurante solo puede crearse con su nombre, slug y dueño (el resto lo decide la plataforma)
revoke insert on restaurants from anon, authenticated;
grant insert (owner_id, name, slug) on restaurants to authenticated;
-- (corrección) el botón "Abierto ahora / Local cerrado" cambia open_now, pero ninguna migración le había dado permiso al dueño
grant update (name, logo_url, tip_pct, open_now) on restaurants to authenticated;

-- 7) Límites de texto en lo que el cliente anónimo puede escribir
do $$ begin
  alter table waiter_calls add constraint waiter_calls_note_len check (note is null or char_length(note) <= 200) not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table orders add constraint orders_table_name_len check (table_name is null or char_length(table_name) <= 60) not valid;
exception when duplicate_object then null; end $$;

-- 8) Índices
create index if not exists orders_rest_status_idx on orders (restaurant_id, status, created_at);
create index if not exists orders_rest_created_idx on orders (restaurant_id, created_at desc);
create index if not exists orders_table_session_idx on orders (table_id, session_id);
create index if not exists products_rest_idx on products (restaurant_id, category);
create index if not exists promotions_rest_idx on promotions (restaurant_id);
create index if not exists dining_tables_rest_idx on dining_tables (restaurant_id);
create index if not exists product_addons_rest_idx on product_addons (restaurant_id);
create index if not exists waiter_calls_rest_idx on waiter_calls (restaurant_id, status);

-- 9) Fotos de productos: solo imágenes, máx. 5 MB, y el dueño puede reemplazarlas o borrarlas (en su carpeta)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('products', 'products', true, 5242880, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['image/png','image/jpeg','image/webp'];
drop policy if exists products_upload on storage.objects;
create policy products_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'products' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));
drop policy if exists products_del on storage.objects;
create policy products_del on storage.objects for delete to authenticated
  using (bucket_id = 'products' and exists (select 1 from restaurants where owner_id = auth.uid() and id::text = (storage.foldername(name))[1]));
