-- Prueba manual de seguridad y permisos. Úsala en una base de PRUEBA (no en producción):
--   1) crea los esquemas simulados de Supabase (auth, storage, roles anon/authenticated)
--   2) ejecuta schema.sql   3) ejecuta este archivo y revisa que cada bloque dé el resultado indicado en su título.
\set ON_ERROR_STOP off
\pset format unaligned
\pset tuples_only on
-- datos base (como superusuario)
insert into auth.users (id,email,email_confirmed_at) values ('11111111-1111-1111-1111-111111111111','dueno@x.cl',now()),('22222222-2222-2222-2222-222222222222','otro@x.cl',now());
set role authenticated; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '--- T1 dueño crea restaurante (name, slug, owner_id)'
insert into restaurants (name,slug,owner_id) values ('Fogon','fogon-1','11111111-1111-1111-1111-111111111111');
\echo '--- T2 dueño intenta crear restaurante con active=false (debe fallar: permission denied)'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into restaurants (name,slug,owner_id,active) values ('Otro','otro-1','22222222-2222-2222-2222-222222222222',false);
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
\echo '--- T3 dueño cambia open_now (debe funcionar) y active (debe fallar)'
update restaurants set open_now = false where owner_id = '11111111-1111-1111-1111-111111111111';
update restaurants set open_now = true where owner_id = '11111111-1111-1111-1111-111111111111';
update restaurants set active = false where owner_id = '11111111-1111-1111-1111-111111111111';
select 'open_now='||open_now||' active='||active from restaurants where slug='fogon-1';
-- catálogo
insert into dining_tables (restaurant_id,name) select id,'Mesa 1' from restaurants where slug='fogon-1';
insert into products (restaurant_id,name,category,price) select id,'Pizza','Platos',10000 from restaurants where slug='fogon-1';
insert into products (restaurant_id,name,category,price) select id,'Bebida','Bebidas',2000 from restaurants where slug='fogon-1';
insert into products (restaurant_id,name,category,price,is_available) select id,'Agotado','Platos',500,false from restaurants where slug='fogon-1';
insert into product_addons (restaurant_id,name,price,product_id) select r.id,'Queso extra',1000,p.id::text from restaurants r, products p where r.slug='fogon-1' and p.name='Pizza';
insert into product_addons (restaurant_id,name,price,category) select id,'Hielo',300,'Bebidas' from restaurants where slug='fogon-1';
insert into promotions (restaurant_id,title,type,product_id,buy_qty,pay_qty) select r.id,'2x1 pizzas','nxm',p.id::text,2,1 from restaurants r, products p where r.slug='fogon-1' and p.name='Bebida';
reset role;
create temp table ids as select (select id from restaurants where slug='fogon-1') rid, (select id from dining_tables limit 1) tid, (select session_id from dining_tables limit 1) sid, (select id::text from products where name='Pizza') pizza, (select id::text from products where name='Bebida') beb, (select id::text from products where name='Agotado') ago, (select id::text from product_addons where name='Queso extra') queso, (select id::text from product_addons where name='Hielo') hielo;
grant select on ids to anon, authenticated;
set role anon;
\echo '--- T4 cliente manda precio falso (price 1, total 1): total real esperado = 10000*2 + 1000*2 = 22000'
insert into orders (restaurant_id,table_id,table_name,session_id,status,total,items,public_id)
select rid,tid,'Mesa 1',sid,'pending',1, jsonb_build_array(jsonb_build_object('id',pizza,'name','HACK','qty',2,'price',1,'addons',jsonb_build_array(jsonb_build_object('id',queso,'name','x','price',0)))), '33333333-3333-3333-3333-333333333333' from ids;
reset role;
select 'total='||total||' items='||items::text from orders where public_id='33333333-3333-3333-3333-333333333333';
set role anon;
\echo '--- T5 promo 2x1 en bebida: 3 bebidas + hielo en una línea = 3*2000+ 3*300 - 1*2000 = 4900'
insert into orders (restaurant_id,table_id,table_name,session_id,status,total,items,public_id)
select rid,tid,'Mesa 1',sid,'pending',0, jsonb_build_array(jsonb_build_object('id',beb,'qty',3,'addons',jsonb_build_array(jsonb_build_object('id',hielo)))), '44444444-4444-4444-4444-444444444444' from ids;
reset role;
select 'total='||total||' promo='||(items->0->>'promo') from orders where public_id='44444444-4444-4444-4444-444444444444';
set role anon;
\echo '--- T6 producto agotado (debe fallar)'
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',ago,'qty',1)) from ids;
\echo '--- T7 agregado de otro producto en la pizza (hielo en pizza, debe fallar)'
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',1,'addons',jsonb_build_array(jsonb_build_object('id',hielo)))) from ids;
\echo '--- T8 cantidad 21 (debe fallar) y qty 0 (debe fallar)'
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',21)) from ids;
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',0)) from ids;
\echo '--- T9 pedido ya pagado (paid_at) debe fallar por política'
insert into orders (restaurant_id,table_id,table_name,session_id,status,paid_at,items) select rid,tid,'Mesa 1',sid,'pending',now(), jsonb_build_array(jsonb_build_object('id',pizza,'qty',1)) from ids;
\echo '--- T10 sesión equivocada (debe fallar por política)'
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',gen_random_uuid(),'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',1)) from ids;
\echo '--- T11 modify_order recalcula: 1 pizza (precio manipulado) -> 10000, historial 1 entrada'
select modify_order('33333333-3333-3333-3333-333333333333', sid, jsonb_build_array(jsonb_build_object('id',pizza,'qty',1,'price',5)), 1) from ids;
select modify_order('33333333-3333-3333-3333-333333333333', sid, jsonb_build_array(jsonb_build_object('id',ago,'qty',1)), 1) from ids;
reset role;
select 'total='||total||' hist='||jsonb_array_length(history)||' prev_total='||(history->0->>'total') from orders where public_id='33333333-3333-3333-3333-333333333333';
set role anon;
\echo '--- T12 cancelar con sesión equivocada / correcta'
select cancel_order('44444444-4444-4444-4444-444444444444', gen_random_uuid());
select cancel_order('44444444-4444-4444-4444-444444444444', sid) from ids;
\echo '--- T13 anónimo no puede leer pedidos (0 filas)'
select count(*) from orders;
\echo '--- T14 table_account (cuenta compartida)'
select count(*) from table_account((select tid from ids),(select sid from ids));
\echo '--- T15 local cerrado: no deja pedir'
reset role; update restaurants set open_now=false; set role anon;
insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',1)) from ids;
reset role; update restaurants set open_now=true;
\echo '--- T16 anti-spam: máx 40 pedidos / 10 min por mesa'
set role anon;
do $$ declare i int; begin for i in 1..45 loop
  begin insert into orders (restaurant_id,table_id,table_name,session_id,status,items) select rid,tid,'Mesa 1',sid,'pending', jsonb_build_array(jsonb_build_object('id',pizza,'qty',1)) from ids;
  exception when others then raise notice 'bloqueado en el intento % : %', i, sqlerrm; exit; end;
end loop; end $$;
reset role;
\echo '--- T17 dueño: charge_table y close_table'
set role authenticated; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select charge_table((select rid from ids),(select tid from ids),'Mesa 1', now(), null);
select close_table((select rid from ids),(select tid from ids),'Mesa 1', false);
select 'sin pagar tras cerrar: '||count(*) from orders where paid_at is null and status<>'cancelled';
\echo '--- T18 otro usuario no puede cerrar mesa ajena'
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select close_table((select rid from ids),(select tid from ids),'Mesa 1', false);
reset role;
\echo '--- T19 admin: no autorizado sin estar en admins'
set role authenticated; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select * from admin_overview();
reset role;
