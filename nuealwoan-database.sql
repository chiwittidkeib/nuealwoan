-- =====================================================================
--  NueaLwoan : ฐานข้อมูล Supabase  (ไฟล์รวม — มีทุกอัปเดตในไฟล์เดียว)
--  วิธีใช้: Supabase > SQL Editor > New query > วางทั้งไฟล์ > Run
--  รันซ้ำได้ทุกเมื่อ ไม่ลบข้อมูลเดิม · มีอัปเดตใหม่ก็รันไฟล์นี้ไฟล์เดียว
-- =====================================================================


-- รายชื่อผู้ใช้ที่มีสิทธิ์เข้าระบบร้าน (owner = เจ้าของ, staff = พนักงาน)
create table if not exists public.staff (
  email text primary key
);
alter table public.staff add column if not exists username   text;
alter table public.staff add column if not exists role       text not null default 'staff';
alter table public.staff add column if not exists created_at timestamptz not null default now();

-- ข้อมูลทั้งหมดของร้าน (เมนู สต็อก บิล ซื้อของ รายจ่าย ตั้งค่า)
create table if not exists public.docs (
  collection text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  status     text   generated always as (data->>'status') stored,
  ts         bigint generated always as (
               coalesce((data->>'paidAt')::numeric, (data->>'at')::numeric)::bigint
             ) stored,
  version    integer not null default 1,
  updated_at timestamptz not null default now(),
  primary key (collection, id)
);
create index if not exists docs_col_status_ts on public.docs (collection, status, ts);

-- เพิ่มเลขเวอร์ชันทุกครั้งที่แก้ (กันข้อมูลชนกันเมื่อหลายเครื่องแก้บิลเดียวกัน)
create or replace function public.docs_bump() returns trigger
language plpgsql as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists docs_bump on public.docs;
create trigger docs_bump before update on public.docs
  for each row execute function public.docs_bump();

-- ---------- สิทธิ์ ----------
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff
    where lower(email) = lower(coalesce(auth.jwt()->>'email', ''))
  );
$$;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.staff
   where lower(email) = lower(coalesce(auth.jwt()->>'email', '')) limit 1;
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.my_role() = 'owner', false);
$$;

alter table public.docs  enable row level security;
alter table public.staff enable row level security;

drop policy if exists docs_staff_all on public.docs;
create policy docs_staff_all on public.docs
  for all to authenticated using (public.is_staff()) with check (public.is_staff());

drop policy if exists staff_read_self on public.staff;
create policy staff_read_self on public.staff
  for select to authenticated
  using (lower(email) = lower(coalesce(auth.jwt()->>'email', '')) or public.is_owner());

-- เจ้าของร้านเพิ่ม/แก้/ลบพนักงานได้ (แต่ลบหรือลดสิทธิ์ตัวเองไม่ได้)
drop policy if exists staff_owner_insert on public.staff;
create policy staff_owner_insert on public.staff for insert to authenticated
  with check (public.is_owner());
drop policy if exists staff_owner_update on public.staff;
create policy staff_owner_update on public.staff for update to authenticated
  using (public.is_owner() and lower(email) <> lower(coalesce(auth.jwt()->>'email', '')))
  with check (public.is_owner());
drop policy if exists staff_owner_delete on public.staff;
create policy staff_owner_delete on public.staff for delete to authenticated
  using (public.is_owner() and lower(email) <> lower(coalesce(auth.jwt()->>'email', '')));

-- ---------- ฟังก์ชันสำหรับแอปพนักงาน ----------
create or replace function public.doc_merge(p_col text, p_id text, p_patch jsonb)
returns integer language plpgsql security invoker set search_path = public as $$
declare v integer;
begin
  update public.docs set data = data || p_patch
   where collection = p_col and id = p_id
   returning version into v;
  if v is null then raise exception 'not_found'; end if;
  return v;
end $$;

create or replace function public.doc_cas(p_col text, p_id text, p_patch jsonb, p_version integer)
returns boolean language plpgsql security invoker set search_path = public as $$
begin
  update public.docs set data = data || p_patch
   where collection = p_col and id = p_id and version = p_version;
  return found;
end $$;

-- ---------- ฟังก์ชันสำหรับลูกค้าสแกน QR (ไม่ต้องล็อกอิน) ----------
create or replace function public._qr_settings(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s jsonb;
begin
  select data into s from public.docs where collection = 'config' and id = 'settings';
  if s is null or coalesce(s->>'qrKey', '') = '' or p_key is null or s->>'qrKey' <> p_key then
    raise exception 'bad_key';
  end if;
  return s;
end $$;

create or replace function public.public_menu(p_key text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s jsonb;
begin
  s := public._qr_settings(p_key);
  return jsonb_build_object(
    'shopName', s->>'shopName',
    'logo',     coalesce(s->>'logo', ''),
    'tables',   coalesce((s->>'tables')::int, 10),
    'cats',     coalesce(s->'cats', '[]'::jsonb),
    'menu',     coalesce((
       select jsonb_agg(jsonb_build_object(
                'id', id, 'name', data->>'name', 'cat', data->>'cat',
                'desc', coalesce(data->>'desc', ''), 'img', coalesce(data->>'img', ''),
                'price', coalesce((data->>'price')::numeric, 0))
              order by data->>'name')
         from public.docs
        where collection = 'menu'
          and coalesce((data->>'active')::boolean, true)), '[]'::jsonb));
end $$;

create or replace function public.customer_status(p_key text, p_table text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare o jsonb; s jsonb; req boolean;
begin
  s := public._qr_settings(p_key);
  req := coalesce((s->>'qrRequireOpen')::boolean, true);
  select data into o from public.docs
   where collection = 'orders' and status = 'open' and data->>'table' = p_table
   order by (data->>'openedAt')::numeric limit 1;
  if o is null then return jsonb_build_object('items', '[]'::jsonb, 'total', 0, 'open', false, 'requireOpen', req); end if;
  return jsonb_build_object(
    'open', true, 'requireOpen', req,
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                 'name', l->>'name', 'qty', (l->>'qty')::int, 'cname', coalesce(l->>'cname', ''),
                 'served', coalesce((l->>'served')::boolean, false),
                 'amount', ((l->>'price')::numeric + coalesce((l->>'extra')::numeric, 0)) * (l->>'qty')::int))
               from jsonb_array_elements(o->'items') l), '[]'::jsonb),
    'total', coalesce((select sum(((l->>'price')::numeric + coalesce((l->>'extra')::numeric, 0)) * (l->>'qty')::int)
               from jsonb_array_elements(o->'items') l), 0));
end $$;

drop function if exists public.customer_add(text, text, jsonb, text);
create or replace function public.customer_add(p_key text, p_table text, p_items jsonb, p_note text, p_name text default '')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  s jsonb; it jsonb; m jsonb; q int; oid text;
  cname text := left(btrim(coalesce(p_name, '')), 40);
  new_items jsonb := '[]'::jsonb;
  now_ms bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
begin
  s := public._qr_settings(p_key);
  if p_table is null or p_table !~ '^[0-9]{1,3}$'
     or p_table::int < 1 or p_table::int > coalesce((s->>'tables')::int, 10) then
    raise exception 'bad_table';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 30 then
    raise exception 'bad_items';
  end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := least(greatest(coalesce((it->>'qty')::int, 0), 0), 20);
    continue when q = 0;
    select data into m from public.docs
     where collection = 'menu' and id = it->>'menuId'
       and coalesce((data->>'active')::boolean, true);
    continue when m is null;
    new_items := new_items || jsonb_build_array(jsonb_build_object(
      'id', substr(md5(random()::text || clock_timestamp()::text), 1, 12),
      'menuId', it->>'menuId', 'name', m->>'name',
      'price', coalesce((m->>'price')::numeric, 0),
      'cost',  coalesce((m->>'cost')::numeric, 0),
      'qty', q, 'note', left(coalesce(p_note, ''), 120), 'extra', 0,
      'served', false, 'by', 'customer', 'cname', cname, 'at', now_ms));
  end loop;
  if jsonb_array_length(new_items) = 0 then raise exception 'empty'; end if;

  perform pg_advisory_xact_lock(hashtext('table:' || p_table));
  select id into oid from public.docs
   where collection = 'orders' and status = 'open' and data->>'table' = p_table
   order by (data->>'openedAt')::numeric limit 1 for update;

  if oid is null then
    if coalesce((s->>'qrRequireOpen')::boolean, true) then raise exception 'table_closed'; end if;
    oid := gen_random_uuid()::text;
    insert into public.docs (collection, id, data) values ('orders', oid,
      jsonb_build_object('status', 'open', 'table', p_table, 'channel', 'dinein', 'openedAt', now_ms, 'items', new_items,
                         'customerName', cname));
  else
    update public.docs
       set data = jsonb_set(data, '{items}', coalesce(data->'items', '[]'::jsonb) || new_items)
                  || case when coalesce(data->>'customerName', '') = '' and cname <> ''
                          then jsonb_build_object('customerName', cname) else '{}'::jsonb end
     where collection = 'orders' and id = oid;
  end if;
  return jsonb_build_object('ok', true, 'added', jsonb_array_length(new_items));
end $$;

revoke all on function public._qr_settings(text) from public, anon, authenticated;
revoke all on function public.doc_merge(text, text, jsonb) from public, anon;
revoke all on function public.doc_cas(text, text, jsonb, integer) from public, anon;
grant execute on function public.doc_merge(text, text, jsonb) to authenticated;
grant execute on function public.doc_cas(text, text, jsonb, integer) to authenticated;
grant execute on function public.is_staff() to authenticated;
grant execute on function public.my_role() to authenticated;
grant execute on function public.is_owner() to authenticated;
revoke all on function public.my_role() from anon;
revoke all on function public.is_owner() from anon;
grant execute on function public.public_menu(text) to anon, authenticated;
grant execute on function public.customer_status(text, text) to anon, authenticated;
grant execute on function public.customer_add(text, text, jsonb, text, text) to anon, authenticated;

-- ---------- ที่เก็บรูปเมนู (Storage) ----------
-- ทุกคนดูรูปได้ (ลูกค้าเห็นรูปในหน้าสั่งอาหาร) แต่เฉพาะพนักงานที่อัปโหลด/ลบได้
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('menu-photos', 'menu-photos', true, 2097152, array['image/jpeg','image/png','image/webp'])
    on conflict (id) do update set public = true;

    execute 'drop policy if exists menu_photos_staff_select on storage.objects';
    execute 'drop policy if exists menu_photos_staff_insert on storage.objects';
    execute 'drop policy if exists menu_photos_staff_update on storage.objects';
    execute 'drop policy if exists menu_photos_staff_delete on storage.objects';
    execute $p$create policy menu_photos_staff_select on storage.objects for select to authenticated
             using (bucket_id = 'menu-photos' and public.is_staff())$p$;
    execute $p$create policy menu_photos_staff_insert on storage.objects for insert to authenticated
             with check (bucket_id = 'menu-photos' and public.is_staff())$p$;
    execute $p$create policy menu_photos_staff_update on storage.objects for update to authenticated
             using (bucket_id = 'menu-photos' and public.is_staff())$p$;
    execute $p$create policy menu_photos_staff_delete on storage.objects for delete to authenticated
             using (bucket_id = 'menu-photos' and public.is_staff())$p$;
  end if;
end $$;

-- เปิดการอัปเดตแบบเรียลไทม์ (ออร์เดอร์ใหม่ขึ้นทุกเครื่องทันที)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- =====================================================================
--  บัญชีเจ้าของร้าน: ชื่อผู้ใช้ "admin"
--  ใน Authentication > Users > Add user ให้ใส่อีเมลเป็น  admin@nuealwoan.com
--  แล้วล็อกอินในแอปด้วยชื่อผู้ใช้  admin  กับรหัสผ่านที่ตั้งไว้
--  พนักงานคนอื่น เจ้าของร้านเพิ่มได้เองในแอป (ตั้งค่าร้าน > พนักงาน)
-- =====================================================================
-- (ใส่ให้เฉพาะตอนติดตั้งครั้งแรกที่ยังไม่มีผู้ใช้เลย รันซ้ำจะไม่สร้าง admin ซ้ำ)
insert into public.staff (email, username, role)
select 'admin@nuealwoan.com', 'admin', 'owner'
 where not exists (select 1 from public.staff);

-- ---------- ข้อมูลเริ่มต้น (ตัวอย่าง แก้ในแอปได้) ----------
insert into public.docs (collection, id, data) values
('config','settings', jsonb_build_object(
  'shopName','NueaLwoan','tables',10,'promptpay','','extraPrice',10,
  'receiptFooter','ขอบคุณที่อุดหนุนครับ','paper',80,'pointsOn',true,'pointsPer',50,'pointValue',1,
  'cats',  '["ก๋วยเตี๋ยว","ข้าว","ของทานเล่น","เครื่องดื่ม"]'::jsonb,
  'expCats','["ค่าเช่า","ค่าแรง","ค่าไฟ/น้ำ","ค่าแก๊ส","อุปกรณ์","อื่นๆ"]'::jsonb,
  'qrKey', substr(md5(random()::text || clock_timestamp()::text), 1, 10))),
('stock','s-small',  '{"name":"เส้นเล็ก","unit":"กก.","qty":5,"min":2,"unitCost":40}'),
('stock','s-big',    '{"name":"เส้นใหญ่","unit":"กก.","qty":5,"min":2,"unitCost":40}'),
('stock','s-egg',    '{"name":"บะหมี่","unit":"ก้อน","qty":40,"min":15,"unitCost":4}'),
('stock','s-ball',   '{"name":"ลูกชิ้นหมู","unit":"กก.","qty":3,"min":1,"unitCost":180}'),
('stock','s-pork',   '{"name":"หมูสับ","unit":"กก.","qty":2,"min":1,"unitCost":160}'),
('stock','s-redpork','{"name":"หมูแดง","unit":"กก.","qty":2,"min":1,"unitCost":220}'),
('stock','s-sprout', '{"name":"ถั่วงอก","unit":"กก.","qty":1.5,"min":1,"unitCost":30}'),
('stock','s-ice',    '{"name":"น้ำแข็ง","unit":"ถุง","qty":2,"min":2,"unitCost":25}'),
('menu','m-small',  '{"name":"เส้นเล็กน้ำใส","cat":"ก๋วยเตี๋ยว","price":50,"cost":22,"active":true,"recipe":[{"stockId":"s-small","qty":0.12},{"stockId":"s-ball","qty":0.05},{"stockId":"s-pork","qty":0.04},{"stockId":"s-sprout","qty":0.03}]}'),
('menu','m-namtok', '{"name":"เส้นใหญ่น้ำตก","cat":"ก๋วยเตี๋ยว","price":55,"cost":24,"active":true,"recipe":[{"stockId":"s-big","qty":0.12},{"stockId":"s-ball","qty":0.05},{"stockId":"s-pork","qty":0.04},{"stockId":"s-sprout","qty":0.03}]}'),
('menu','m-tomyum', '{"name":"เส้นเล็กต้มยำ","cat":"ก๋วยเตี๋ยว","price":55,"cost":25,"active":true,"recipe":[{"stockId":"s-small","qty":0.12},{"stockId":"s-ball","qty":0.05},{"stockId":"s-pork","qty":0.05}]}'),
('menu','m-bami',   '{"name":"บะหมี่แห้งหมูแดง","cat":"ก๋วยเตี๋ยว","price":55,"cost":23,"active":true,"recipe":[{"stockId":"s-egg","qty":1},{"stockId":"s-redpork","qty":0.05}]}'),
('menu','m-kaolao', '{"name":"เกาเหลาลูกชิ้น","cat":"ก๋วยเตี๋ยว","price":50,"cost":22,"active":true,"recipe":[{"stockId":"s-ball","qty":0.08},{"stockId":"s-pork","qty":0.04}]}'),
('menu','m-rice',   '{"name":"ข้าวหมูแดง","cat":"ข้าว","price":55,"cost":24,"active":true,"recipe":[{"stockId":"s-redpork","qty":0.07}]}'),
('menu','m-kiew',   '{"name":"เกี๊ยวทอด","cat":"ของทานเล่น","price":40,"cost":12,"active":true,"recipe":[]}'),
('menu','m-tea',    '{"name":"ชาเย็น","cat":"เครื่องดื่ม","price":25,"cost":8,"active":true,"recipe":[]}'),
('menu','m-water',  '{"name":"น้ำเปล่า","cat":"เครื่องดื่ม","price":10,"cost":4,"active":true,"recipe":[]}'),
('menu','m-ice',    '{"name":"น้ำแข็งเปล่า","cat":"เครื่องดื่ม","price":5,"cost":1,"active":true,"recipe":[]}')
on conflict (collection, id) do nothing;

-- สร้างบัญชีใหม่ (เฉพาะเจ้าของร้าน)
create or replace function public.admin_create_user(p_username text, p_password text, p_role text default 'staff')
returns text
language plpgsql volatile security definer
set search_path = public, extensions, auth
as $$
declare
  me     text := lower(coalesce(auth.jwt()->>'email', ''));
  domain text := split_part(me, '@', 2);
  uname  text := lower(btrim(coalesce(p_username, '')));
  mail   text;
  uid    uuid := gen_random_uuid();
  now_ts timestamptz := now();
begin
  if not public.is_owner() then raise exception 'not_owner'; end if;
  if uname !~ '^[a-z0-9._-]{3,30}$' then raise exception 'bad_username'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'weak_password'; end if;
  if p_role not in ('owner', 'staff') then raise exception 'bad_role'; end if;
  if domain = '' then raise exception 'not_owner'; end if;
  mail := uname || '@' || domain;
  if exists (select 1 from auth.users where lower(email) = mail) then raise exception 'user_exists'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', mail,
          crypt(p_password, gen_salt('bf')), now_ts,
          '{"provider":"email","providers":["email"]}'::jsonb,
          jsonb_build_object('username', uname), now_ts, now_ts, '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, 'email',
          jsonb_build_object('sub', uid::text, 'email', mail, 'email_verified', true),
          now_ts, now_ts, now_ts);

  insert into public.staff (email, username, role) values (mail, uname, p_role)
  on conflict (email) do update set username = excluded.username, role = excluded.role;
  return mail;
end $$;

-- ตั้งรหัสผ่านใหม่ให้ผู้ใช้ (เฉพาะเจ้าของร้าน)
create or replace function public.admin_set_password(p_username text, p_password text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, auth
as $$
declare
  mail text := lower(btrim(coalesce(p_username, ''))) || '@' || split_part(lower(coalesce(auth.jwt()->>'email', '')), '@', 2);
begin
  if not public.is_owner() then raise exception 'not_owner'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'weak_password'; end if;
  if not exists (select 1 from public.staff where lower(email) = mail) then raise exception 'no_user'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
   where lower(email) = mail;
  if not found then raise exception 'no_user'; end if;
end $$;

-- ลบบัญชี (เฉพาะเจ้าของร้าน และลบตัวเองไม่ได้)
create or replace function public.admin_delete_user(p_username text)
returns void
language plpgsql volatile security definer
set search_path = public, extensions, auth
as $$
declare
  me   text := lower(coalesce(auth.jwt()->>'email', ''));
  mail text := lower(btrim(coalesce(p_username, ''))) || '@' || split_part(me, '@', 2);
begin
  if not public.is_owner() then raise exception 'not_owner'; end if;
  if mail = me then raise exception 'self_delete'; end if;
  delete from public.staff where lower(email) = mail;
  delete from auth.users where lower(email) = mail;
end $$;

revoke all on function public.admin_create_user(text, text, text) from public, anon;
revoke all on function public.admin_set_password(text, text)      from public, anon;
revoke all on function public.admin_delete_user(text)             from public, anon;
grant execute on function public.admin_create_user(text, text, text) to authenticated;
grant execute on function public.admin_set_password(text, text)      to authenticated;
grant execute on function public.admin_delete_user(text)             to authenticated;


-- 1) ตั้งค่าร้านและตารางสิทธิ์ แก้ได้เฉพาะแอดมิน (เลขที่บิลยังให้ทุกคนเขียนได้)
drop policy if exists docs_staff_all    on public.docs;
drop policy if exists docs_staff_select on public.docs;
drop policy if exists docs_staff_insert on public.docs;
drop policy if exists docs_staff_update on public.docs;
drop policy if exists docs_staff_delete on public.docs;
create policy docs_staff_select on public.docs for select to authenticated
  using (public.is_staff());
create policy docs_staff_insert on public.docs for insert to authenticated
  with check (public.is_staff() and (collection <> 'config' or id = 'counter' or public.is_owner()));
create policy docs_staff_update on public.docs for update to authenticated
  using      (public.is_staff() and (collection <> 'config' or id = 'counter' or public.is_owner()))
  with check (public.is_staff() and (collection <> 'config' or id = 'counter' or public.is_owner()));
create policy docs_staff_delete on public.docs for delete to authenticated
  using (public.is_staff() and (collection <> 'config' or id = 'counter' or public.is_owner()));

-- 2) ตำแหน่งเดิม "staff" เปลี่ยนเป็น "พนักงานเสิร์ฟ"
update public.staff set role = 'waiter' where role = 'staff';
alter table public.staff alter column role set default 'waiter';

-- 3) สิทธิ์เริ่มต้นของแต่ละตำแหน่ง (แอดมินแก้ได้ในแอป: ตั้งค่าร้าน > สิทธิ์การใช้งาน)
insert into public.docs (collection, id, data) values ('config', 'permissions', '{
  "roles": {
    "waiter":  {"tables": true, "kitchen": true, "pay": true, "members": true},
    "chef":    {"kitchen": true, "stock": true},
    "partner": {"report": true, "expenses": true, "stock": true, "members": true}
  }}'::jsonb)
on conflict (collection, id) do nothing;

-- 4) สร้างบัญชีด้วยตำแหน่งใหม่ได้
create or replace function public.admin_create_user(p_username text, p_password text, p_role text default 'waiter')
returns text
language plpgsql volatile security definer
set search_path = public, extensions, auth
as $$
declare
  me     text := lower(coalesce(auth.jwt()->>'email', ''));
  domain text := split_part(me, '@', 2);
  uname  text := lower(btrim(coalesce(p_username, '')));
  mail   text;
  uid    uuid := gen_random_uuid();
  now_ts timestamptz := now();
begin
  if not public.is_owner() then raise exception 'not_owner'; end if;
  if uname !~ '^[a-z0-9._-]{3,30}$' then raise exception 'bad_username'; end if;
  if length(coalesce(p_password, '')) < 6 then raise exception 'weak_password'; end if;
  if p_role not in ('owner', 'waiter', 'chef', 'partner') then raise exception 'bad_role'; end if;
  if domain = '' then raise exception 'not_owner'; end if;
  mail := uname || '@' || domain;
  if exists (select 1 from auth.users where lower(email) = mail) then raise exception 'user_exists'; end if;

  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', mail,
          crypt(p_password, gen_salt('bf')), now_ts,
          '{"provider":"email","providers":["email"]}'::jsonb,
          jsonb_build_object('username', uname), now_ts, now_ts, '', '', '', '');

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text, 'email',
          jsonb_build_object('sub', uid::text, 'email', mail, 'email_verified', true),
          now_ts, now_ts, now_ts);

  insert into public.staff (email, username, role) values (mail, uname, p_role)
  on conflict (email) do update set username = excluded.username, role = excluded.role;
  return mail;
end $$;

-- 5) ตำแหน่งในตาราง staff ต้องเป็นค่าที่รู้จัก
alter table public.staff drop constraint if exists staff_role_check;
alter table public.staff add constraint staff_role_check check (role in ('owner', 'waiter', 'chef', 'partner'));
