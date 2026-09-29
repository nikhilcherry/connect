-- Connect core schema.
--
-- Privacy model: the person who scans a tag never touches these tables. Every
-- scanner action goes through the `scan` edge function (service role), which
-- only ever returns make/model/colour. Owners read and write their own rows
-- through RLS. Anon/authenticated get no table privileges beyond what the
-- policies below need.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- vehicles
create table public.vehicles (
  id               uuid primary key default gen_random_uuid(),
  owner            uuid not null default auth.uid() references auth.users(id) on delete cascade,
  reg_number       text not null check (reg_number ~ '^[A-Z0-9]{6,11}$'),
  make             text not null check (char_length(make) between 1 and 40),
  model            text not null check (char_length(model) between 1 and 60),
  colour           text check (char_length(colour) <= 30),
  nickname         text check (char_length(nickname) <= 40),
  length_mm        int check (length_mm between 2000 and 7000),
  width_mm         int check (width_mm between 1000 and 2600),
  height_mm        int check (height_mm between 1000 and 2600),
  puc_expiry       date,
  insurance_expiry date,
  service_due      date,
  created_at       timestamptz not null default now(),
  unique (owner, reg_number)
);
create index on public.vehicles (owner);

-- ---------------------------------------------------------------- tags
-- Codes use an alphabet without 0/O/1/I/L so they survive being read aloud or
-- typed from a faded sticker. 8 chars over 31 symbols ~ 8.5e11 codes, far too
-- many to enumerate through a rate-limited endpoint.
create or replace function public.gen_tag_code() returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea := gen_random_bytes(8);
  code text := '';
begin
  for i in 0..7 loop
    code := code || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
  end loop;
  return code;
end $$;

create table public.tags (
  code       text primary key default public.gen_tag_code(),
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create index on public.tags (vehicle_id);

-- ---------------------------------------------------------------- alerts
create table public.alerts (
  id                 uuid primary key default gen_random_uuid(),
  tag_code           text not null references public.tags(code) on delete cascade,
  vehicle_id         uuid not null references public.vehicles(id) on delete cascade,
  owner              uuid not null references auth.users(id) on delete cascade,
  kind               text not null check (kind in ('blocking','lights_on','towing','accident','window_open','other')),
  note               text check (char_length(note) <= 280),
  status             text not null default 'open' check (status in ('open','on_my_way','resolved')),
  blocked            boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on public.alerts (owner, created_at desc);
create index on public.alerts (tag_code, created_at desc);

-- Scanner secrets live apart from alerts so owners (and realtime, which reads
-- whole rows under the owner's role) never see them. No grants: service role only.
create table public.alert_scanners (
  alert_id   uuid primary key references public.alerts(id) on delete cascade,
  token_hash text not null,
  ip_hash    text not null
);
create index on public.alert_scanners (ip_hash);

create table public.alert_messages (
  id         bigint generated always as identity primary key,
  alert_id   uuid not null references public.alerts(id) on delete cascade,
  sender     text not null check (sender in ('owner','scanner')),
  body       text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now()
);
create index on public.alert_messages (alert_id, id);

-- Owner-side block list, keyed on the salted IP hash the edge function stores.
create table public.blocked_scanners (
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  ip_hash    text not null,
  created_at timestamptz not null default now(),
  primary key (owner, ip_hash)
);

-- ---------------------------------------------------------------- emergency contacts
create table public.emergency_contacts (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 1 and 60),
  phone      text not null check (phone ~ '^\+?[0-9]{10,13}$'),
  created_at timestamptz not null default now()
);
create index on public.emergency_contacts (owner);

-- ---------------------------------------------------------------- privileges
-- Supabase grants full DML on new public tables by default; RLS would then be
-- the only barrier. Revoke, then grant back exactly what the app uses.
revoke all on public.vehicles, public.tags, public.alerts, public.alert_messages, public.alert_scanners,
              public.blocked_scanners, public.emergency_contacts from anon, authenticated;

grant select, insert, update, delete on public.vehicles, public.emergency_contacts to authenticated;
grant select, insert, update on public.tags to authenticated;
grant select on public.alerts to authenticated;
grant update (status) on public.alerts to authenticated;
grant select, insert on public.alert_messages to authenticated;
grant select, insert, delete on public.blocked_scanners to authenticated;

alter table public.vehicles           enable row level security;
alter table public.tags               enable row level security;
alter table public.alerts             enable row level security;
alter table public.alert_messages     enable row level security;
alter table public.alert_scanners     enable row level security;
alter table public.blocked_scanners   enable row level security;
alter table public.emergency_contacts enable row level security;

create policy own_vehicles on public.vehicles for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

create policy own_contacts on public.emergency_contacts for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

create policy own_tags on public.tags for all to authenticated
  using (owner = auth.uid())
  with check (owner = auth.uid()
              and exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner = auth.uid()));

create policy own_alerts_read on public.alerts for select to authenticated
  using (owner = auth.uid());
create policy own_alerts_status on public.alerts for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

create policy own_messages_read on public.alert_messages for select to authenticated
  using (exists (select 1 from public.alerts a where a.id = alert_id and a.owner = auth.uid()));
create policy own_messages_send on public.alert_messages for insert to authenticated
  with check (sender = 'owner'
              and exists (select 1 from public.alerts a where a.id = alert_id and a.owner = auth.uid()));

create policy own_blocks on public.blocked_scanners for all to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

-- Blocking an alert's sender without ever exposing the hash to the client.
create or replace function public.block_alert_sender(p_alert uuid) returns void
language plpgsql security definer set search_path = public as $$
declare h text;
begin
  select s.ip_hash into h from alert_scanners s join alerts a on a.id = s.alert_id
   where a.id = p_alert and a.owner = auth.uid();
  if h is null then raise exception 'not found'; end if;
  insert into blocked_scanners (owner, ip_hash) values (auth.uid(), h) on conflict do nothing;
  update alerts set blocked = true, status = 'resolved', updated_at = now()
   where owner = auth.uid()
     and id in (select alert_id from alert_scanners where ip_hash = h);
end $$;
revoke all on function public.block_alert_sender(uuid) from public, anon;
grant execute on function public.block_alert_sender(uuid) to authenticated;

create or replace function public.touch_alert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update alerts set updated_at = now() where id = new.alert_id;
  return new;
end $$;
create trigger alert_messages_touch after insert on public.alert_messages
  for each row execute function public.touch_alert();

-- ---------------------------------------------------------------- realtime
alter publication supabase_realtime add table public.alerts, public.alert_messages;

-- Wrong plate-digit guesses from the scan page, for lockout. Service role only.
create table public.scan_failures (
  id         bigint generated always as identity primary key,
  ip_hash    text not null,
  tag_code   text not null,
  created_at timestamptz not null default now()
);
create index on public.scan_failures (ip_hash, created_at desc);
revoke all on public.scan_failures from anon, authenticated;
alter table public.scan_failures enable row level security;
