-- Simula lo mínimo de Supabase (roles, auth, storage) para probar el SQL en un PostgreSQL común.
create role anon nologin; create role authenticated nologin; create role service_role nologin;
create schema auth; create table auth.users (id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;
create schema storage;
create table storage.buckets (id text primary key, name text, public bool, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
create function storage.foldername(name text) returns text[] language sql as $$ select (string_to_array(name,'/'))[1:greatest(array_length(string_to_array(name,'/'),1)-1,0)] $$;
create publication supabase_realtime;
grant usage on schema public, auth, storage to anon, authenticated;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
grant select on auth.users to authenticated;
grant all on storage.objects, storage.buckets to authenticated;
