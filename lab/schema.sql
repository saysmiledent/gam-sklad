-- GAM CLINIC — Лаборатория. Схема базы (Supabase / Postgres)
-- Все таблицы с префиксом lab_, доступ только через функции (RPC) с токеном сессии.

create table if not exists lab_labs (
  id serial primary key,
  name text not null,
  active boolean not null default true
);

create table if not exists lab_users (
  id serial primary key,
  role text not null check (role in ('super','admin','doctor','assistant','lab')),
  name text not null,
  login text unique,
  pass_hash text,
  pin_hash text,
  lab_id int references lab_labs(id),
  active boolean not null default true,
  fails int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists lab_sessions (
  token uuid primary key default gen_random_uuid(),
  user_id int not null references lab_users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create table if not exists lab_patients (
  id serial primary key,
  fio text not null,
  created_by int references lab_users(id),
  created_at timestamptz not null default now()
);
create index if not exists lab_patients_fio on lab_patients (lower(fio));

create table if not exists lab_catalog (
  id serial primary key,
  grp text not null,
  name text not null,
  returnable boolean not null default true,
  sort int not null default 0,
  active boolean not null default true
);

create table if not exists lab_orders (
  id serial primary key,
  patient_id int not null references lab_patients(id),
  lab_id int not null references lab_labs(id),
  doctor_id int references lab_users(id),
  work_type text not null,
  teeth int[] not null default '{}',
  implant boolean not null default false,
  implant_system text,
  method text,
  temp boolean not null default false,
  material text,
  shade text,
  shade_note text,
  notes text,
  due_date date,
  status text not null default 'new' check (status in ('new','at_lab','lab_ready','at_clinic','delivered','cancelled')),
  purpose text,
  delayed boolean not null default false,
  delay_note text,
  remakes int not null default 0,
  was_late boolean not null default false,
  created_by int references lab_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists lab_orders_patient on lab_orders(patient_id);

create table if not exists lab_moves (
  id serial primary key,
  order_id int not null references lab_orders(id),
  catalog_id int references lab_catalog(id),
  name text not null,
  qty int not null check (qty > 0),
  kind text not null check (kind in ('out','back','writeoff')),
  returnable boolean not null default true,
  note text,
  user_id int references lab_users(id),
  created_at timestamptz not null default now()
);
create index if not exists lab_moves_order on lab_moves(order_id);

create table if not exists lab_msgs (
  id bigserial primary key,
  order_id int not null references lab_orders(id),
  user_id int references lab_users(id),
  kind text not null default 'msg' check (kind in ('msg','event')),
  text text,
  created_at timestamptz not null default now()
);
create index if not exists lab_msgs_order on lab_msgs(order_id);

create table if not exists lab_files (
  id bigserial primary key,
  order_id int not null references lab_orders(id),
  msg_id bigint references lab_msgs(id),
  path text not null unique,
  name text not null,
  size bigint not null default 0,
  mime text,
  user_id int references lab_users(id),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists lab_files_order on lab_files(order_id);

create table if not exists lab_reads (
  user_id int not null references lab_users(id) on delete cascade,
  order_id int not null references lab_orders(id),
  last_id bigint not null default 0,
  primary key (user_id, order_id)
);

do $$ declare t text; begin
  foreach t in array array['lab_labs','lab_users','lab_sessions','lab_patients','lab_catalog','lab_orders','lab_moves','lab_msgs','lab_files','lab_reads'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- ===================== внутренние помощники =====================
create or replace function lab__me(p_token uuid) returns lab_users
language plpgsql security definer set search_path = public, extensions as $$
declare u lab_users;
begin
  select u2.* into u from lab_sessions s join lab_users u2 on u2.id = s.user_id
   where s.token = p_token and s.expires_at > now() and u2.active;
  if not found then raise exception 'AUTH'; end if;
  return u;
end $$;

create or replace function lab__clinic(u lab_users) returns void
language plpgsql as $$
begin
  if u.role = 'lab' then raise exception 'FORBIDDEN'; end if;
end $$;

create or replace function lab__order(u lab_users, p_id int, p_lock boolean default false) returns lab_orders
language plpgsql security definer set search_path = public, extensions as $$
declare o lab_orders;
begin
  if p_lock then select * into o from lab_orders where id = p_id for update;
  else select * into o from lab_orders where id = p_id; end if;
  if not found then raise exception 'NOTFOUND'; end if;
  if u.role = 'lab' and o.lab_id is distinct from u.lab_id then raise exception 'FORBIDDEN'; end if;
  return o;
end $$;

create or replace function lab__event(p_order int, p_user int, p_text text) returns void
language sql security definer set search_path = public as $$
  insert into lab_msgs(order_id, user_id, kind, text) values (p_order, p_user, 'event', p_text);
$$;

create or replace function lab__today() returns date language sql stable as $$
  select (now() at time zone 'Europe/Moscow')::date;
$$;

create or replace function lab__plabel(p text) returns text language sql immutable as $$
  select case p
    when 'make' then 'изготовление'
    when 'next' then 'следующий этап'
    when 'fix' then 'доработка'
    when 'try1' then 'первичная примерка'
    when 'try2' then 'финальная примерка'
    when 'final' then 'сдача пациенту'
    else coalesce(p, '') end;
$$;

create or replace function lab__mejson(u lab_users) returns jsonb language sql immutable as $$
  select jsonb_build_object('id', u.id, 'role', u.role, 'name', u.name, 'lab_id', u.lab_id);
$$;

create or replace function lab__session(u lab_users, p_remember boolean) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare t uuid;
begin
  delete from lab_sessions where expires_at < now();
  update lab_users set fails = 0, locked_until = null where id = u.id;
  insert into lab_sessions(user_id, expires_at)
  values (u.id, now() + case when coalesce(p_remember, true) then interval '60 days' else interval '12 hours' end)
  returning token into t;
  return jsonb_build_object('ok', true, 'token', t, 'me', lab__mejson(u));
end $$;

create or replace function lab__fail(u lab_users) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  update lab_users set fails = fails + 1,
    locked_until = case when fails + 1 >= 5 then now() + interval '10 minutes' else null end
  where id = u.id;
  return jsonb_build_object('ok', false, 'err', 'BADLOGIN');
end $$;

create or replace function lab__notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid int;
begin
  oid := coalesce((to_jsonb(new)->>'order_id')::int, (to_jsonb(new)->>'id')::int);
  begin
    perform realtime.send(jsonb_build_object('o', oid), 'chg', 'gamlab', false);
  exception when others then null;
  end;
  return null;
end $$;

drop trigger if exists lab_msgs_notify on lab_msgs;
create trigger lab_msgs_notify after insert on lab_msgs for each row execute function lab__notify();
drop trigger if exists lab_orders_notify on lab_orders;
create trigger lab_orders_notify after insert or update on lab_orders for each row execute function lab__notify();

-- ===================== вход =====================
create or replace function lab_setup_needed() returns boolean
language sql security definer set search_path = public as $$
  select not exists (select 1 from lab_users where role = 'super');
$$;

create or replace function lab_setup(p_name text, p_login text, p_pass text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u lab_users;
begin
  perform pg_advisory_xact_lock(424242);
  if exists (select 1 from lab_users where role = 'super') then raise exception 'EXISTS'; end if;
  if nullif(trim(p_name), '') is null or nullif(trim(p_login), '') is null then raise exception 'EMPTY'; end if;
  if length(coalesce(p_pass, '')) < 6 then raise exception 'SHORTPASS'; end if;
  insert into lab_users(role, name, login, pass_hash)
  values ('super', trim(p_name), lower(trim(p_login)), crypt(p_pass, gen_salt('bf'))) returning * into u;
  return lab__session(u, true);
end $$;

create or replace function lab_login(p_login text, p_pass text, p_remember boolean default true) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u lab_users;
begin
  select * into u from lab_users where login = lower(trim(p_login)) and active and role <> 'assistant';
  if not found then perform pg_sleep(0.4); return jsonb_build_object('ok', false, 'err', 'BADLOGIN'); end if;
  if u.locked_until > now() then return jsonb_build_object('ok', false, 'err', 'LOCKED'); end if;
  if u.pass_hash is null or crypt(coalesce(p_pass, ''), u.pass_hash) <> u.pass_hash then return lab__fail(u); end if;
  return lab__session(u, p_remember);
end $$;

create or replace function lab_pin_list() returns jsonb
language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]'::jsonb)
  from lab_users where role = 'assistant' and active;
$$;

create or replace function lab_pin_login(p_id int, p_pin text, p_remember boolean default true) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u lab_users;
begin
  select * into u from lab_users where id = p_id and role = 'assistant' and active;
  if not found then return jsonb_build_object('ok', false, 'err', 'BADLOGIN'); end if;
  if u.locked_until > now() then return jsonb_build_object('ok', false, 'err', 'LOCKED'); end if;
  if u.pin_hash is null or crypt(coalesce(p_pin, ''), u.pin_hash) <> u.pin_hash then return lab__fail(u); end if;
  return lab__session(u, p_remember);
end $$;

create or replace function lab_logout(p_token uuid) returns void
language sql security definer set search_path = public as $$
  delete from lab_sessions where token = p_token;
$$;

create or replace function lab_change_pass(p_token uuid, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u lab_users;
begin
  u := lab__me(p_token);
  if u.role = 'assistant' then raise exception 'FORBIDDEN'; end if;
  if crypt(coalesce(p_old, ''), u.pass_hash) <> u.pass_hash then return jsonb_build_object('ok', false, 'err', 'BADLOGIN'); end if;
  if length(coalesce(p_new, '')) < 6 then raise exception 'SHORTPASS'; end if;
  update lab_users set pass_hash = crypt(p_new, gen_salt('bf')) where id = u.id;
  return jsonb_build_object('ok', true);
end $$;

-- ===================== чтение =====================
create or replace function lab_boot(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users; used bigint;
begin
  u := lab__me(p_token);
  if u.role in ('super','admin') then
    select coalesce(sum((metadata->>'size')::bigint), 0) into used from storage.objects;
  end if;
  return jsonb_build_object(
    'me', lab__mejson(u),
    'labs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active) order by id), '[]') from lab_labs),
    'doctors', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]') from lab_users where role in ('doctor','super') and active),
    'catalog', (select coalesce(jsonb_agg(to_jsonb(c) order by c.sort, c.id), '[]') from lab_catalog c where u.role = 'super' or c.active),
    'storage', used
  );
end $$;

create or replace function lab_list(p_token uuid, p_q text default null, p_all boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users; q text := nullif(trim(coalesce(p_q, '')), ''); qn text;
begin
  u := lab__me(p_token);
  qn := nullif(regexp_replace(coalesce(q, ''), '\D', '', 'g'), '');
  return (select coalesce(jsonb_agg(x), '[]') from (
    select o.id, o.status, o.purpose, o.work_type, o.teeth, o.implant, o.implant_system, o.temp, o.material, o.shade,
           o.due_date as due, o.delayed, o.remakes, o.doctor_id, o.lab_id, o.created_at, o.updated_at, o.closed_at,
           p.id as patient_id, p.fio, d.name as doctor,
           (select coalesce(sum(case when m.kind = 'out' then m.qty else -m.qty end), 0) from lab_moves m where m.order_id = o.id and m.returnable) as away,
           (select count(*) from lab_msgs g where g.order_id = o.id and g.user_id is distinct from u.id
              and g.id > coalesce((select r.last_id from lab_reads r where r.user_id = u.id and r.order_id = o.id), 0)) as unread
      from lab_orders o join lab_patients p on p.id = o.patient_id left join lab_users d on d.id = o.doctor_id
     where (u.role <> 'lab' or (o.lab_id = u.lab_id and o.status <> 'cancelled'))
       and (p_all or q is not null or o.status not in ('delivered','cancelled') or o.closed_at > now() - interval '45 days')
       and (q is null or p.fio ilike '%' || q || '%' or (qn is not null and o.id::text = ltrim(qn, '0')))
     order by o.due_date nulls last, o.id
     limit 500) x);
end $$;

create or replace function lab_order(p_token uuid, p_id int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders; res jsonb; mx bigint;
begin
  u := lab__me(p_token);
  o := lab__order(u, p_id);
  select coalesce(max(id), 0) into mx from lab_msgs where order_id = p_id;
  res := jsonb_build_object(
    'order', to_jsonb(o) || jsonb_build_object(
        'fio', (select fio from lab_patients where id = o.patient_id),
        'doctor', (select name from lab_users where id = o.doctor_id),
        'lab', (select name from lab_labs where id = o.lab_id),
        'author', (select name from lab_users where id = o.created_by)),
    'siblings', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'status', s.status, 'work_type', s.work_type, 'teeth', s.teeth) order by s.id), '[]')
                   from lab_orders s where s.patient_id = o.patient_id and (u.role <> 'lab' or (s.lab_id = u.lab_id and s.status <> 'cancelled'))),
    'items', (select coalesce(jsonb_agg(i order by i.name), '[]') from (
                select m.name, max(m.catalog_id) as catalog_id, bool_or(m.returnable) as returnable,
                       sum(m.qty) filter (where m.kind = 'out') as sent,
                       coalesce(sum(m.qty) filter (where m.kind = 'back'), 0) as back,
                       coalesce(sum(m.qty) filter (where m.kind = 'writeoff'), 0) as woff
                  from lab_moves m where m.order_id = p_id group by m.name) i),
    'msgs', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', g.id, 'kind', g.kind, 'text', g.text, 'at', g.created_at, 'user_id', g.user_id,
                'name', w.name, 'role', w.role,
                'files', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'path', f.path, 'name', f.name, 'size', f.size, 'mime', f.mime, 'deleted', f.deleted_at is not null) order by f.id), '[]')
                            from lab_files f where f.msg_id = g.id)) order by g.id), '[]')
               from lab_msgs g left join lab_users w on w.id = g.user_id where g.order_id = p_id)
  );
  insert into lab_reads(user_id, order_id, last_id) values (u.id, p_id, mx)
  on conflict (user_id, order_id) do update set last_id = excluded.last_id;
  return res;
end $$;

create or replace function lab_patients_find(p_token uuid, p_q text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users;
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  return (select coalesce(jsonb_agg(x), '[]') from (
    select p.id, p.fio, (select count(*) from lab_orders o where o.patient_id = p.id) as orders
      from lab_patients p where p.fio ilike '%' || trim(p_q) || '%' order by p.fio limit 12) x);
end $$;

create or replace function lab_away(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users;
begin
  u := lab__me(p_token);
  return (select coalesce(jsonb_agg(x order by x.name, x.order_id), '[]') from (
    select m.name, m.order_id, o.status, p.fio,
           sum(case when m.kind = 'out' then m.qty else -m.qty end) as qty
      from lab_moves m join lab_orders o on o.id = m.order_id join lab_patients p on p.id = o.patient_id
     where m.returnable and (u.role <> 'lab' or o.lab_id = u.lab_id)
     group by m.name, m.order_id, o.status, p.fio
    having sum(case when m.kind = 'out' then m.qty else -m.qty end) > 0) x);
end $$;

-- ===================== работы =====================
create or replace function lab_save_order(p_token uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders; pid int; oid int; t int[];
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  if nullif(trim(p->>'work_type'), '') is null then raise exception 'EMPTY'; end if;
  t := array(select (jsonb_array_elements_text(coalesce(p->'teeth', '[]'::jsonb)))::int);
  if (p->>'id') is null then
    pid := (p->>'patient_id')::int;
    if pid is null then
      if nullif(trim(p->>'fio'), '') is null then raise exception 'EMPTY'; end if;
      insert into lab_patients(fio, created_by) values (regexp_replace(trim(p->>'fio'), '\s+', ' ', 'g'), u.id) returning id into pid;
    end if;
    insert into lab_orders(patient_id, lab_id, doctor_id, work_type, teeth, implant, implant_system, method, temp, material, shade, shade_note, notes, due_date, created_by)
    values (pid, coalesce((p->>'lab_id')::int, (select min(id) from lab_labs where active)), (p->>'doctor_id')::int,
            trim(p->>'work_type'), t, coalesce((p->>'implant')::boolean, false), nullif(p->>'implant_system', ''), nullif(p->>'method', ''),
            coalesce((p->>'temp')::boolean, false), nullif(p->>'material', ''), nullif(p->>'shade', ''), nullif(trim(p->>'shade_note'), ''),
            nullif(trim(p->>'notes'), ''), nullif(p->>'due_date', '')::date, u.id)
    returning id into oid;
    perform lab__event(oid, u.id, 'Работа оформлена');
  else
    oid := (p->>'id')::int;
    o := lab__order(u, oid, true);
    if o.status in ('delivered','cancelled') then raise exception 'CLOSED'; end if;
    update lab_orders set
      lab_id = coalesce((p->>'lab_id')::int, lab_id), doctor_id = (p->>'doctor_id')::int, work_type = trim(p->>'work_type'), teeth = t,
      implant = coalesce((p->>'implant')::boolean, false), implant_system = nullif(p->>'implant_system', ''), method = nullif(p->>'method', ''),
      temp = coalesce((p->>'temp')::boolean, false), material = nullif(p->>'material', ''), shade = nullif(p->>'shade', ''),
      shade_note = nullif(trim(p->>'shade_note'), ''), notes = nullif(trim(p->>'notes'), ''), due_date = nullif(p->>'due_date', '')::date,
      updated_at = now()
    where id = oid;
    if nullif(trim(p->>'fio'), '') is not null then
      update lab_patients set fio = regexp_replace(trim(p->>'fio'), '\s+', ' ', 'g') where id = o.patient_id;
    end if;
    perform lab__event(oid, u.id, 'Параметры работы изменены');
  end if;
  return oid;
end $$;

create or replace function lab_send(p_token uuid, p_id int, p_purpose text, p_due date, p_items jsonb, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders; lst text;
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  o := lab__order(u, p_id, true);
  if o.status not in ('new','at_clinic') then raise exception 'BADSTATE'; end if;
  if p_purpose not in ('make','next','fix') then raise exception 'EMPTY'; end if;
  if p_purpose = 'fix' and nullif(trim(coalesce(p_note, '')), '') is null then raise exception 'NOTE'; end if;
  insert into lab_moves(order_id, catalog_id, name, qty, kind, returnable, user_id)
  select p_id, c.id, coalesce(c.name, trim(e->>'name')), (e->>'qty')::int, 'out',
         coalesce(c.returnable, coalesce((e->>'returnable')::boolean, true)), u.id
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e
    left join lab_catalog c on c.id = (e->>'catalog_id')::int
   where coalesce((e->>'qty')::int, 0) > 0 and coalesce(c.name, nullif(trim(e->>'name'), '')) is not null;
  select string_agg('• ' || coalesce(c.name, trim(e->>'name')) || ' — ' || (e->>'qty') || ' шт', E'\n') into lst
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e left join lab_catalog c on c.id = (e->>'catalog_id')::int
   where coalesce((e->>'qty')::int, 0) > 0;
  update lab_orders set status = 'at_lab', purpose = p_purpose, due_date = coalesce(p_due, due_date), delayed = false, delay_note = null,
         remakes = remakes + case when p_purpose = 'fix' then 1 else 0 end, updated_at = now()
   where id = p_id;
  perform lab__event(p_id, u.id,
    'Отправлено в лабораторию: ' || lab__plabel(p_purpose)
    || coalesce(E'\nВизит пациента: ' || to_char(coalesce(p_due, o.due_date), 'DD.MM.YYYY'), '')
    || coalesce(E'\n' || lst, E'\nБез предметов')
    || coalesce(E'\n' || nullif(trim(p_note), ''), ''));
end $$;

create or replace function lab_ready(p_token uuid, p_id int, p_purpose text, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders;
begin
  u := lab__me(p_token);
  if u.role not in ('lab','super') then raise exception 'FORBIDDEN'; end if;
  o := lab__order(u, p_id, true);
  if o.status <> 'at_lab' then raise exception 'BADSTATE'; end if;
  if p_purpose not in ('try1','try2','final') then raise exception 'EMPTY'; end if;
  update lab_orders set status = 'lab_ready', purpose = p_purpose, delayed = false, delay_note = null, updated_at = now() where id = p_id;
  perform lab__event(p_id, u.id, 'Лаборатория: работа готова и передана в клинику — ' || lab__plabel(p_purpose)
    || coalesce(E'\n' || nullif(trim(p_note), ''), ''));
end $$;

create or replace function lab_delay(p_token uuid, p_id int, p_on boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders;
begin
  u := lab__me(p_token);
  if u.role not in ('lab','super') then raise exception 'FORBIDDEN'; end if;
  o := lab__order(u, p_id, true);
  if o.status <> 'at_lab' then raise exception 'BADSTATE'; end if;
  update lab_orders set delayed = p_on, delay_note = case when p_on then nullif(trim(p_note), '') end, updated_at = now() where id = p_id;
  perform lab__event(p_id, u.id, case when p_on then 'Лаборатория: работа задерживается' || coalesce(E'\n' || nullif(trim(p_note), ''), '')
                                      else 'Лаборатория: задержка снята' end);
end $$;

create or replace function lab_receive(p_token uuid, p_id int, p_purpose text) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders; late boolean;
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  o := lab__order(u, p_id, true);
  if o.status not in ('at_lab','lab_ready') then raise exception 'BADSTATE'; end if;
  late := o.due_date is not null and lab__today() > o.due_date;
  update lab_orders set status = 'at_clinic', purpose = coalesce(nullif(p_purpose, ''), purpose, 'final'), delayed = false, delay_note = null,
         was_late = was_late or late, updated_at = now() where id = p_id;
  perform lab__event(p_id, u.id, 'Работа получена в клинике — ' || lab__plabel(coalesce(nullif(p_purpose, ''), o.purpose, 'final'))
    || case when late then E'\nПозже даты визита' else '' end);
end $$;

create or replace function lab_items_back(p_token uuid, p_id int, p_items jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders; lst text;
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  o := lab__order(u, p_id, true);
  insert into lab_moves(order_id, catalog_id, name, qty, kind, returnable, note, user_id)
  select p_id, (e->>'catalog_id')::int, e->>'name', (e->>'qty')::int, case when e->>'kind' = 'writeoff' then 'writeoff' else 'back' end,
         true, nullif(trim(e->>'note'), ''), u.id
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e where coalesce((e->>'qty')::int, 0) > 0;
  select string_agg('• ' || (e->>'name') || ' — ' || (e->>'qty') || ' шт'
           || case when e->>'kind' = 'writeoff' then ' (списано' || coalesce(': ' || nullif(trim(e->>'note'), ''), '') || ')' else '' end, E'\n') into lst
    from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e where coalesce((e->>'qty')::int, 0) > 0;
  if lst is null then return; end if;
  perform lab__event(p_id, u.id, 'Предметы приняты в клинике:' || E'\n' || lst);
end $$;

create or replace function lab_deliver(p_token uuid, p_id int) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders;
begin
  u := lab__me(p_token);
  perform lab__clinic(u);
  o := lab__order(u, p_id, true);
  if o.status <> 'at_clinic' then raise exception 'BADSTATE'; end if;
  update lab_orders set status = 'delivered', closed_at = now(), updated_at = now() where id = p_id;
  perform lab__event(p_id, u.id, 'Работа сдана пациенту. Заказ закрыт');
end $$;

create or replace function lab_cancel(p_token uuid, p_id int, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare u lab_users; o lab_orders;
begin
  u := lab__me(p_token);
  if u.role not in ('super','admin','doctor') then raise exception 'FORBIDDEN'; end if;
  o := lab__order(u, p_id, true);
  if o.status in ('delivered','cancelled') then raise exception 'BADSTATE'; end if;
  update lab_orders set status = 'cancelled', closed_at = now(), updated_at = now() where id = p_id;
  perform lab__event(p_id, u.id, 'Заказ отменён' || coalesce(E'\n' || nullif(trim(p_note), ''), ''));
end $$;

create or replace function lab_msg(p_token uuid, p_id int, p_text text, p_files jsonb) returns bigint
language plpgsql security definer set search_path = public, storage as $$
declare u lab_users; o lab_orders; mid bigint; f jsonb; sz bigint;
begin
  u := lab__me(p_token);
  o := lab__order(u, p_id);
  if nullif(trim(coalesce(p_text, '')), '') is null and jsonb_array_length(coalesce(p_files, '[]'::jsonb)) = 0 then raise exception 'EMPTY'; end if;
  insert into lab_msgs(order_id, user_id, kind, text) values (p_id, u.id, 'msg', nullif(trim(coalesce(p_text, '')), '')) returning id into mid;
  for f in select * from jsonb_array_elements(coalesce(p_files, '[]'::jsonb)) loop
    if (f->>'path') not like p_id || '/%' then raise exception 'FORBIDDEN'; end if;
    select (metadata->>'size')::bigint into sz from storage.objects where bucket_id = 'lab-files' and name = f->>'path';
    if not found then raise exception 'NOFILE'; end if;
    insert into lab_files(order_id, msg_id, path, name, size, mime, user_id)
    values (p_id, mid, f->>'path', coalesce(nullif(f->>'name', ''), 'file'), coalesce(sz, 0), f->>'mime', u.id);
  end loop;
  return mid;
end $$;

-- ===================== настройки (суперадмин) =====================
create or replace function lab__super(p_token uuid) returns lab_users
language plpgsql security definer set search_path = public as $$
declare u lab_users;
begin
  u := lab__me(p_token);
  if u.role <> 'super' then raise exception 'FORBIDDEN'; end if;
  return u;
end $$;

create or replace function lab_users_list(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform lab__super(p_token);
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'role', role, 'name', name, 'login', login, 'lab_id', lab_id,
            'active', active, 'locked', locked_until > now()) order by active desc, role, name), '[]') from lab_users);
end $$;

create or replace function lab__pin() returns text language sql volatile as $$
  select lpad((floor(random() * 10000))::int::text, 4, '0');
$$;

create or replace function lab_user_save(p_token uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare me lab_users; uid int; r text := p->>'role'; pin text; pw text := nullif(p->>'password', '');
begin
  me := lab__super(p_token);
  if r not in ('super','admin','doctor','assistant','lab') or nullif(trim(p->>'name'), '') is null then raise exception 'EMPTY'; end if;
  if r <> 'assistant' and nullif(trim(p->>'login'), '') is null then raise exception 'EMPTY'; end if;
  if r = 'lab' and (p->>'lab_id') is null then raise exception 'EMPTY'; end if;
  if pw is not null and length(pw) < 6 then raise exception 'SHORTPASS'; end if;
  uid := (p->>'id')::int;
  if uid = me.id and (r <> 'super' or not coalesce((p->>'active')::boolean, true)) then raise exception 'SELF'; end if;
  begin
    if uid is null then
      if r <> 'assistant' and pw is null then raise exception 'SHORTPASS'; end if;
      if r = 'assistant' then pin := lab__pin(); end if;
      insert into lab_users(role, name, login, pass_hash, pin_hash, lab_id)
      values (r, trim(p->>'name'), case when r <> 'assistant' then lower(trim(p->>'login')) end,
              case when r <> 'assistant' then crypt(pw, gen_salt('bf')) end,
              case when r = 'assistant' then crypt(pin, gen_salt('bf')) end,
              case when r = 'lab' then (p->>'lab_id')::int end)
      returning id into uid;
    else
      update lab_users set role = r, name = trim(p->>'name'),
        login = case when r <> 'assistant' then lower(trim(p->>'login')) end,
        pass_hash = case when r = 'assistant' then null when pw is not null then crypt(pw, gen_salt('bf')) else pass_hash end,
        lab_id = case when r = 'lab' then (p->>'lab_id')::int end,
        active = coalesce((p->>'active')::boolean, active), fails = 0, locked_until = null
      where id = uid;
      if r = 'assistant' and (select pin_hash from lab_users where id = uid) is null then
        pin := lab__pin();
        update lab_users set pin_hash = crypt(pin, gen_salt('bf')) where id = uid;
      end if;
      if r <> 'assistant' and (select pass_hash from lab_users where id = uid) is null then raise exception 'SHORTPASS'; end if;
      if not coalesce((p->>'active')::boolean, true) then delete from lab_sessions where user_id = uid; end if;
    end if;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'err', 'LOGIN_TAKEN');
  end;
  return jsonb_build_object('ok', true, 'id', uid, 'pin', pin);
end $$;

create or replace function lab_user_pin(p_token uuid, p_id int) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare pin text := lab__pin();
begin
  perform lab__super(p_token);
  update lab_users set pin_hash = crypt(pin, gen_salt('bf')), fails = 0, locked_until = null where id = p_id and role = 'assistant';
  if not found then raise exception 'NOTFOUND'; end if;
  delete from lab_sessions where user_id = p_id;
  return pin;
end $$;

create or replace function lab_lab_save(p_token uuid, p_id int, p_name text, p_active boolean) returns int
language plpgsql security definer set search_path = public as $$
declare lid int;
begin
  perform lab__super(p_token);
  if nullif(trim(p_name), '') is null then raise exception 'EMPTY'; end if;
  if p_id is null then insert into lab_labs(name) values (trim(p_name)) returning id into lid;
  else update lab_labs set name = trim(p_name), active = coalesce(p_active, active) where id = p_id returning id into lid; end if;
  return lid;
end $$;

create or replace function lab_cat_save(p_token uuid, p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare cid int;
begin
  perform lab__super(p_token);
  if nullif(trim(p->>'name'), '') is null or nullif(trim(p->>'grp'), '') is null then raise exception 'EMPTY'; end if;
  if (p->>'id') is null then
    insert into lab_catalog(grp, name, returnable, sort)
    values (trim(p->>'grp'), trim(p->>'name'), coalesce((p->>'returnable')::boolean, true),
            coalesce((p->>'sort')::int, (select coalesce(max(sort), 0) + 10 from lab_catalog)))
    returning id into cid;
  else
    update lab_catalog set grp = trim(p->>'grp'), name = trim(p->>'name'), returnable = coalesce((p->>'returnable')::boolean, returnable),
           sort = coalesce((p->>'sort')::int, sort), active = coalesce((p->>'active')::boolean, active)
     where id = (p->>'id')::int returning id into cid;
  end if;
  return cid;
end $$;

-- ===================== статистика и место =====================
create or replace function lab_stats(p_token uuid, p_from date, p_to date) returns jsonb
language plpgsql security definer set search_path = public as $$
declare u lab_users;
begin
  u := lab__me(p_token);
  if u.role not in ('super','admin') then raise exception 'FORBIDDEN'; end if;
  return jsonb_build_object(
    'months', (select coalesce(jsonb_agg(s order by s.m), '[]') from (
      select to_char(date_trunc('month', created_at at time zone 'Europe/Moscow'), 'YYYY-MM') as m,
             count(*) as total,
             count(*) filter (where status = 'delivered') as delivered,
             round((avg(extract(epoch from closed_at - created_at) / 86400) filter (where status = 'delivered'))::numeric, 1) as avg_days,
             count(*) filter (where remakes > 0) as remade,
             coalesce(sum(remakes), 0) as remakes,
             count(*) filter (where was_late) as late
        from lab_orders
       where status <> 'cancelled' and (created_at at time zone 'Europe/Moscow')::date between p_from and p_to
       group by 1) s),
    'rows', (select coalesce(jsonb_agg(r order by r.id), '[]') from (
      select o.id, o.created_at, p.fio, d.name as doctor, l.name as lab, o.work_type, o.teeth, o.implant_system, o.method,
             o.temp, o.material, o.shade, o.status, o.due_date, o.closed_at, o.remakes, o.was_late
        from lab_orders o join lab_patients p on p.id = o.patient_id left join lab_users d on d.id = o.doctor_id join lab_labs l on l.id = o.lab_id
       where (o.created_at at time zone 'Europe/Moscow')::date between p_from and p_to) r)
  );
end $$;

create or replace function lab_storage(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, storage as $$
begin
  perform lab__super(p_token);
  return jsonb_build_object(
    'used', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects),
    'lab', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'lab-files'),
    'limit', 1073741824,
    'closed', (select coalesce(jsonb_agg(x order by x.closed_at), '[]') from (
      select o.id, p.fio, o.closed_at, sum(f.size) as bytes, count(*) as files
        from lab_orders o join lab_patients p on p.id = o.patient_id join lab_files f on f.order_id = o.id and f.deleted_at is null
       where o.status in ('delivered','cancelled')
       group by o.id, p.fio, o.closed_at) x)
  );
end $$;

-- права на функции: внутренние помощники закрыты
revoke execute on function lab__me(uuid), lab__clinic(lab_users), lab__order(lab_users, int, boolean), lab__event(int, int, text),
  lab__session(lab_users, boolean), lab__fail(lab_users), lab__notify(), lab__super(uuid), lab__pin(), lab__mejson(lab_users),
  lab__plabel(text), lab__today() from public, anon, authenticated;

-- хранилище файлов
insert into storage.buckets (id, name, public, file_size_limit)
values ('lab-files', 'lab-files', false, 52428800)
on conflict (id) do nothing;

-- начальные данные
insert into lab_labs(name) select 'Лаборатория' where not exists (select 1 from lab_labs);

insert into lab_catalog(grp, name, returnable, sort)
select * from (values
  ('Ложки', 'Ложка оттискная №1 — верх', true, 10), ('Ложки', 'Ложка оттискная №1 — низ', true, 11),
  ('Ложки', 'Ложка оттискная №2 — верх', true, 12), ('Ложки', 'Ложка оттискная №2 — низ', true, 13),
  ('Ложки', 'Ложка оттискная №3 — верх', true, 14), ('Ложки', 'Ложка оттискная №3 — низ', true, 15),
  ('Ложки', 'Ложка оттискная №4 — верх', true, 16), ('Ложки', 'Ложка оттискная №4 — низ', true, 17),
  ('Ложки', 'Ложка оттискная №5 — верх', true, 18), ('Ложки', 'Ложка оттискная №5 — низ', true, 19),
  ('Straumann', 'Трансфер Straumann NC (открытая ложка)', true, 30), ('Straumann', 'Трансфер Straumann NC (закрытая ложка)', true, 31),
  ('Straumann', 'Трансфер Straumann RC (открытая ложка)', true, 32), ('Straumann', 'Трансфер Straumann RC (закрытая ложка)', true, 33),
  ('Straumann', 'Аналог Straumann NC', true, 34), ('Straumann', 'Аналог Straumann RC', true, 35),
  ('Straumann', 'Скан-боди Straumann NC', true, 36), ('Straumann', 'Скан-боди Straumann RC', true, 37),
  ('Straumann', 'Винт Straumann', true, 38),
  ('Medentika', 'Трансфер Medentika (открытая ложка)', true, 50), ('Medentika', 'Трансфер Medentika (закрытая ложка)', true, 51),
  ('Medentika', 'Аналог Medentika', true, 52), ('Medentika', 'Скан-боди Medentika', true, 53), ('Medentika', 'Винт Medentika', true, 54),
  ('Прочее', 'Гипсовая модель', true, 70), ('Прочее', 'Временная коронка пациента', true, 71),
  ('Прочее', 'Оттиск (слепок)', false, 72), ('Прочее', 'Регистрат прикуса', false, 73)
) v(grp, name, returnable, sort)
where not exists (select 1 from lab_catalog);

-- v2: удаление предметов каталога (если предмет уже отправлялся — только скрывается)
create or replace function lab_cat_delete(p_token uuid, p_id int) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform lab__super(p_token);
  if exists (select 1 from lab_moves where catalog_id = p_id) then
    update lab_catalog set active = false where id = p_id;
    return 'hidden';
  end if;
  delete from lab_catalog where id = p_id;
  return 'deleted';
end $$;
