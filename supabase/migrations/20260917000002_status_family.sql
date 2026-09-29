-- "Back by 6:30" owner status and sharing a car with family.

-- ---------------------------------------------------------------- owner status
-- Shown to a stranger only after they've proved they're at the car (plate
-- check) and sent an alert, so a sticker photo shared online can't be used to
-- learn when a car will be left unattended.
alter table public.vehicles
  add column back_at   timestamptz,
  add column away_note text check (char_length(away_note) <= 60);

-- ---------------------------------------------------------------- family
-- Members get the owner's view of a car: its alerts, chat, renewals and
-- "back by" status. Only the owner can change the plate, delete the car,
-- pause or replace its tag, or invite people.
create table public.vehicle_members (
  vehicle_id   uuid not null references public.vehicles(id) on delete cascade,
  member       uuid not null references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 30),
  created_at   timestamptz not null default now(),
  primary key (vehicle_id, member)
);
create index on public.vehicle_members (member);

-- One-time join codes: 6 chars over 31 symbols ~ 8.9e8, a 24 h expiry and 10
-- wrong tries an hour per account make guessing pointless.
create table public.vehicle_invites (
  code       text primary key,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '24 hours',
  used_by    uuid references auth.users(id) on delete set null
);
create index on public.vehicle_invites (vehicle_id);

create table public.invite_failures (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index on public.invite_failures (user_id, created_at desc);

revoke all on public.vehicle_members, public.vehicle_invites, public.invite_failures from anon, authenticated;
alter table public.vehicle_members enable row level security;
alter table public.vehicle_invites enable row level security;
alter table public.invite_failures enable row level security;

-- Security definer so policies on vehicles can call it without recursing
-- through the vehicles policy itself.
create or replace function public.can_access_vehicle(p_vehicle uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from vehicles where id = p_vehicle and owner = auth.uid())
      or exists (select 1 from vehicle_members where vehicle_id = p_vehicle and member = auth.uid());
$$;
revoke all on function public.can_access_vehicle(uuid) from public, anon;
grant execute on function public.can_access_vehicle(uuid) to authenticated;

grant select, delete on public.vehicle_members to authenticated;

create policy family_read on public.vehicle_members for select to authenticated
  using (public.can_access_vehicle(vehicle_id));
-- The owner removes anyone; a member can leave.
create policy family_remove on public.vehicle_members for delete to authenticated
  using (member = auth.uid()
         or exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner = auth.uid()));

-- Vehicles: members read and update; only the owner deletes.
drop policy own_vehicles on public.vehicles;
-- The inline owner check matters: on insert ... returning, the new row isn't
-- yet visible to can_access_vehicle's snapshot.
create policy vehicles_read on public.vehicles for select to authenticated
  using (owner = auth.uid() or public.can_access_vehicle(id));
create policy vehicles_insert on public.vehicles for insert to authenticated
  with check (owner = auth.uid());
create policy vehicles_update on public.vehicles for update to authenticated
  using (owner = auth.uid() or public.can_access_vehicle(id))
  with check (owner = auth.uid() or public.can_access_vehicle(id));
create policy vehicles_delete on public.vehicles for delete to authenticated
  using (owner = auth.uid());
-- Nobody moves a car to another account through the API.
revoke update on public.vehicles from authenticated;
grant update (reg_number, make, model, colour, nickname, length_mm, width_mm, height_mm,
              puc_expiry, insurance_expiry, service_due, back_at, away_note)
  on public.vehicles to authenticated;

-- The plate is what the scan page checks strangers against, so a member
-- changing it would lock out real alerts.
create or replace function public.guard_reg_number() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.reg_number is distinct from old.reg_number and auth.uid() is distinct from old.owner
     and auth.role() = 'authenticated' then
    raise exception 'only the owner can change the number plate' using errcode = '42501';
  end if;
  return new;
end $$;
create trigger vehicles_guard_reg before update on public.vehicles
  for each row execute function public.guard_reg_number();

-- Tags: members see the code (to show or share the sticker); owner manages it.
drop policy own_tags on public.tags;
create policy tags_read on public.tags for select to authenticated
  using (public.can_access_vehicle(vehicle_id));
create policy tags_insert on public.tags for insert to authenticated
  with check (owner = auth.uid()
              and exists (select 1 from public.vehicles v where v.id = vehicle_id and v.owner = auth.uid()));
create policy tags_update on public.tags for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());

-- Alerts and chat: anyone in the family can read, reply and update status.
drop policy own_alerts_read on public.alerts;
drop policy own_alerts_status on public.alerts;
create policy alerts_read on public.alerts for select to authenticated
  using (public.can_access_vehicle(vehicle_id));
create policy alerts_status on public.alerts for update to authenticated
  using (public.can_access_vehicle(vehicle_id)) with check (public.can_access_vehicle(vehicle_id));

drop policy own_messages_read on public.alert_messages;
drop policy own_messages_send on public.alert_messages;
create policy messages_read on public.alert_messages for select to authenticated
  using (exists (select 1 from public.alerts a where a.id = alert_id and public.can_access_vehicle(a.vehicle_id)));
create policy messages_send on public.alert_messages for insert to authenticated
  with check (sender = 'owner'
              and exists (select 1 from public.alerts a where a.id = alert_id and public.can_access_vehicle(a.vehicle_id)));

-- Blocks go on the car owner's list so they apply to the whole family.
create or replace function public.block_alert_sender(p_alert uuid) returns void
language plpgsql security definer set search_path = public as $$
declare h text; o uuid;
begin
  select s.ip_hash, a.owner into h, o from alert_scanners s join alerts a on a.id = s.alert_id
   where a.id = p_alert and can_access_vehicle(a.vehicle_id);
  if h is null then raise exception 'not found'; end if;
  insert into blocked_scanners (owner, ip_hash) values (o, h) on conflict do nothing;
  update alerts set blocked = true, status = 'resolved', updated_at = now()
   where owner = o
     and id in (select alert_id from alert_scanners where ip_hash = h);
end $$;

-- ---------------------------------------------------------------- invite flow
create or replace function public.create_vehicle_invite(p_vehicle uuid) returns text
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes bytea;
  c text;
begin
  if not exists (select 1 from vehicles where id = p_vehicle and owner = auth.uid()) then
    raise exception 'not found';
  end if;
  -- One live code per car: a new one replaces any unused one.
  delete from vehicle_invites where vehicle_id = p_vehicle and used_by is null;
  loop
    bytes := gen_random_bytes(6);
    c := '';
    for i in 0..5 loop
      c := c || substr(alphabet, (get_byte(bytes, i) % 31) + 1, 1);
    end loop;
    begin
      insert into vehicle_invites (code, vehicle_id) values (c, p_vehicle);
      return c;
    exception when unique_violation then
      null; -- astronomically rare; pick another
    end;
  end loop;
end $$;

-- Returns the vehicle id joined. A wrong, expired or used code all give the
-- same error so a guesser learns nothing.
create or replace function public.accept_vehicle_invite(p_code text, p_name text) returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare inv vehicle_invites; members int;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if (select count(*) from invite_failures
       where user_id = auth.uid() and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'too_many_attempts';
  end if;

  select * into inv from vehicle_invites
   where code = upper(trim(p_code)) and used_by is null and expires_at > now()
   for update;
  if inv.code is null or exists (select 1 from vehicles where id = inv.vehicle_id and owner = auth.uid()) then
    insert into invite_failures (user_id) values (auth.uid());
    -- Keep the failure row: a raised exception would roll it back.
    return null;
  end if;

  select count(*) into members from vehicle_members where vehicle_id = inv.vehicle_id;
  if members >= 5 then raise exception 'family_full'; end if;

  insert into vehicle_members (vehicle_id, member, display_name)
  values (inv.vehicle_id, auth.uid(), coalesce(nullif(left(trim(p_name), 30), ''), 'Family'))
  on conflict (vehicle_id, member) do nothing;
  update vehicle_invites set used_by = auth.uid() where code = inv.code;
  return inv.vehicle_id;
end $$;

revoke all on function public.create_vehicle_invite(uuid) from public, anon;
revoke all on function public.accept_vehicle_invite(text, text) from public, anon;
grant execute on function public.create_vehicle_invite(uuid) to authenticated;
grant execute on function public.accept_vehicle_invite(text, text) to authenticated;
