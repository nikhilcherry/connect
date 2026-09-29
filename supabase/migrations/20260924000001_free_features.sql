-- Free-features round two: medical info for accident scans, photos on alerts,
-- push tokens, housing-society mode and live trip sharing.

-- ---------------------------------------------------------------- medical info
-- Opt-in. Reaches a stranger only on an accident alert, after the plate check,
-- through the scan function's `thread` action; never from a bare lookup.
alter table public.vehicles
  add column blood_group   text check (blood_group in ('A+','A-','B+','B-','AB+','AB-','O+','O-')),
  add column medical_note  text check (char_length(medical_note) <= 120),
  add column medical_share boolean not null default false;

grant update (blood_group, medical_note, medical_share) on public.vehicles to authenticated;

-- ---------------------------------------------------------------- alert photos
-- A stranger may attach one photo (damage, a blocked gate). The scan function
-- uploads it with the service role; owners and family read it via a signed
-- URL. Photos are deleted after 7 days by the scan function's sweep.
alter table public.alerts add column photo_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('alert-photos', 'alert-photos', false, 716800, array['image/jpeg'])
on conflict (id) do nothing;

create policy alert_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'alert-photos'
         and exists (select 1 from public.alerts a
                      where a.photo_path = storage.objects.name
                        and public.can_access_vehicle(a.vehicle_id)));

-- ---------------------------------------------------------------- push tokens
-- One row per device. Alerts reach a closed app through FCM, so the app no
-- longer needs a realtime connection open in the background.
create table public.push_tokens (
  token      text primary key check (char_length(token) between 20 and 4096),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  platform   text not null default 'android' check (platform in ('android','ios','web')),
  updated_at timestamptz not null default now()
);
create index on public.push_tokens (user_id);

revoke all on public.push_tokens from anon, authenticated;
grant select, delete on public.push_tokens to authenticated;
alter table public.push_tokens enable row level security;
create policy own_push_tokens on public.push_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- A token moves with the phone: re-registering after a reinstall (new
-- anonymous account) must take it over, which RLS alone won't allow.
create or replace function public.register_push_token(p_token text, p_platform text default 'android') returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  insert into push_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), coalesce(p_platform, 'android'), now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;
revoke all on function public.register_push_token(text, text) from public, anon;
grant execute on function public.register_push_token(text, text) to authenticated;

-- ---------------------------------------------------------------- societies
-- An apartment or office admin sees how many cars are tagged and broadcasts
-- notices ("Move cars for cleaning, Sunday 8am"). Members see notices and a
-- count; only the admin sees the roster (flat + car model, never plates).
create table public.societies (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 2 and 60),
  admin      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  join_code  text not null unique,
  created_at timestamptz not null default now()
);

create table public.society_members (
  society_id uuid not null references public.societies(id) on delete cascade,
  member     uuid not null references auth.users(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  flat       text check (char_length(flat) <= 20),
  created_at timestamptz not null default now(),
  primary key (society_id, member)
);
create index on public.society_members (member);

create table public.society_notices (
  id         bigint generated always as identity primary key,
  society_id uuid not null references public.societies(id) on delete cascade,
  author     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now(),
  pushed_at  timestamptz
);
create index on public.society_notices (society_id, created_at desc);

revoke all on public.societies, public.society_members, public.society_notices from anon, authenticated;
alter table public.societies       enable row level security;
alter table public.society_members enable row level security;
alter table public.society_notices enable row level security;

create or replace function public.is_society_member(p_society uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from societies where id = p_society and admin = auth.uid())
      or exists (select 1 from society_members where society_id = p_society and member = auth.uid());
$$;
create or replace function public.is_society_admin(p_society uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from societies where id = p_society and admin = auth.uid());
$$;
revoke all on function public.is_society_member(uuid), public.is_society_admin(uuid) from public, anon;
grant execute on function public.is_society_member(uuid), public.is_society_admin(uuid) to authenticated;

-- Columns listed so the join code never leaves the database through a select.
grant select (id, name, admin, created_at), delete on public.societies to authenticated;
grant update (name) on public.societies to authenticated;
grant select, delete on public.society_members to authenticated;
grant update (flat, vehicle_id) on public.society_members to authenticated;
grant select, delete on public.society_notices to authenticated;
grant insert (society_id, body) on public.society_notices to authenticated;

create policy societies_read on public.societies for select to authenticated
  using (admin = auth.uid() or public.is_society_member(id));
create policy societies_admin_update on public.societies for update to authenticated
  using (admin = auth.uid()) with check (admin = auth.uid());
create policy societies_admin_delete on public.societies for delete to authenticated
  using (admin = auth.uid());

-- Members see their own row; the admin sees everyone's.
create policy smembers_read on public.society_members for select to authenticated
  using (member = auth.uid() or public.is_society_admin(society_id));
create policy smembers_update on public.society_members for update to authenticated
  using (member = auth.uid())
  with check (member = auth.uid() and (vehicle_id is null or public.can_access_vehicle(vehicle_id)));
-- The admin can't leave their own society; they delete it instead.
create policy smembers_remove on public.society_members for delete to authenticated
  using ((member = auth.uid() and not public.is_society_admin(society_id))
         or (public.is_society_admin(society_id) and member <> auth.uid()));

create policy notices_read on public.society_notices for select to authenticated
  using (public.is_society_member(society_id));
create policy notices_post on public.society_notices for insert to authenticated
  with check (author = auth.uid() and public.is_society_admin(society_id));
create policy notices_delete on public.society_notices for delete to authenticated
  using (public.is_society_admin(society_id));

create or replace function public._join_code(len int) returns text
language plpgsql volatile set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea := gen_random_bytes(len);
  c text := '';
begin
  for i in 0..len - 1 loop
    c := c || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
  end loop;
  return c;
end $$;
revoke all on function public._join_code(int) from public, anon, authenticated;

-- The admin joins their own society as its first member.
create or replace function public.create_society(p_name text, p_flat text default null, p_vehicle uuid default null) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare sid uuid; c text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if (select count(*) from societies where admin = auth.uid()) >= 3 then raise exception 'too_many_societies'; end if;
  if p_vehicle is not null and not can_access_vehicle(p_vehicle) then raise exception 'not found'; end if;
  loop
    c := _join_code(6);
    begin
      insert into societies (name, admin, join_code) values (trim(p_name), auth.uid(), c) returning id into sid;
      exit;
    exception when unique_violation then null;
    end;
  end loop;
  insert into society_members (society_id, member, vehicle_id, flat)
  values (sid, auth.uid(), p_vehicle, nullif(left(trim(coalesce(p_flat, '')), 20), ''));
  return sid;
end $$;

-- Same lockout as family invites. Returns null on a wrong code, so the
-- failure row isn't rolled back by a raised exception.
create or replace function public.join_society(p_code text, p_flat text default null, p_vehicle uuid default null) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare sid uuid; n int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if (select count(*) from invite_failures
       where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_attempts';
  end if;
  if p_vehicle is not null and not can_access_vehicle(p_vehicle) then raise exception 'not found'; end if;
  select id into sid from societies where join_code = upper(trim(p_code));
  if sid is null then
    insert into invite_failures (user_id) values (auth.uid());
    return null;
  end if;
  select count(*) into n from society_members where society_id = sid;
  if n >= 500 then raise exception 'society_full'; end if;
  insert into society_members (society_id, member, vehicle_id, flat)
  values (sid, auth.uid(), p_vehicle, nullif(left(trim(coalesce(p_flat, '')), 20), ''))
  on conflict (society_id, member) do update set vehicle_id = excluded.vehicle_id, flat = excluded.flat;
  return sid;
end $$;

-- Only the admin sees the join code: it goes on the society notice board.
create or replace function public.society_join_code(p_society uuid) returns text
language sql stable security definer set search_path = public as $$
  select join_code from societies where id = p_society and admin = auth.uid();
$$;

create or replace function public.society_stats(p_society uuid) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_society_member(p_society) then raise exception 'not found'; end if;
  return json_build_object(
    'members', (select count(*) from society_members where society_id = p_society),
    'tagged', (select count(distinct m.vehicle_id) from society_members m
                 join tags t on t.vehicle_id = m.vehicle_id and t.active
                where m.society_id = p_society));
end $$;

-- The admin's roster: flat and car model, never the plate or a phone number.
create or replace function public.society_roster(p_society uuid)
returns table (member uuid, flat text, car text, tagged boolean, joined_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_society_admin(p_society) then raise exception 'not found'; end if;
  return query
    select m.member, m.flat,
           case when v.id is null then null else trim(coalesce(v.colour || ' ', '') || v.make || ' ' || v.model) end,
           exists (select 1 from tags t where t.vehicle_id = m.vehicle_id and t.active),
           m.created_at
      from society_members m left join vehicles v on v.id = m.vehicle_id
     where m.society_id = p_society
     order by m.flat nulls last, m.created_at;
end $$;

revoke all on function public.create_society(text, text, uuid), public.join_society(text, text, uuid),
  public.society_join_code(uuid), public.society_stats(uuid), public.society_roster(uuid) from public, anon;
grant execute on function public.create_society(text, text, uuid), public.join_society(text, text, uuid),
  public.society_join_code(uuid), public.society_stats(uuid), public.society_roster(uuid) to authenticated;

-- ---------------------------------------------------------------- live trips
-- The owner shares a link; the viewer page polls the scan function (no
-- realtime connection per viewer). The link carries a random token; only its
-- hash is stored. Trips end on their own after at most 12 hours.
create table public.trips (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  token_hash text not null unique,
  started_at timestamptz not null default now(),
  ends_at    timestamptz not null,
  stopped    boolean not null default false,
  lat        double precision check (lat between -90 and 90),
  lng        double precision check (lng between -180 and 180),
  accuracy_m real,
  speed_mps  real,
  trail      jsonb not null default '[]'::jsonb check (jsonb_typeof(trail) = 'array' and jsonb_array_length(trail) <= 120),
  updated_at timestamptz
);
create index on public.trips (owner, started_at desc);

revoke all on public.trips from anon, authenticated;
grant select (id, owner, vehicle_id, started_at, ends_at, stopped, lat, lng, accuracy_m, speed_mps, trail, updated_at)
  on public.trips to authenticated;
grant update (stopped, lat, lng, accuracy_m, speed_mps, trail, updated_at) on public.trips to authenticated;
alter table public.trips enable row level security;
create policy own_trips_read on public.trips for select to authenticated using (owner = auth.uid());
create policy own_trips_update on public.trips for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

-- Returns the token for the share link. Starting a trip ends any other.
create or replace function public.start_trip(p_vehicle uuid, p_hours int default 4) returns json
language plpgsql volatile security definer set search_path = public, extensions as $$
declare tok text := encode(gen_random_bytes(18), 'hex'); tid uuid;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_vehicle is not null and not can_access_vehicle(p_vehicle) then raise exception 'not found'; end if;
  update trips set stopped = true where owner = auth.uid() and not stopped;
  insert into trips (owner, vehicle_id, token_hash, ends_at)
  values (auth.uid(), p_vehicle, encode(digest(tok, 'sha256'), 'hex'),
          now() + make_interval(hours => least(greatest(coalesce(p_hours, 4), 1), 12)))
  returning id into tid;
  return json_build_object('id', tid, 'token', tok);
end $$;
revoke all on function public.start_trip(uuid, int) from public, anon;
grant execute on function public.start_trip(uuid, int) to authenticated;
