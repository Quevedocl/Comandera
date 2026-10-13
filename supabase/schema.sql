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
