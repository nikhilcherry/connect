-- Everything the onboarding read off the car photo and the RC beyond the columns
-- above (body type, fuel, chassis tail, what was verified and when). Kept as one
-- json document so a new field needs no migration.
alter table public.vehicles
  add column details jsonb not null default '{}'::jsonb
    check (jsonb_typeof(details) = 'object' and pg_column_size(details) <= 4096);

grant update (details) on public.vehicles to authenticated;
