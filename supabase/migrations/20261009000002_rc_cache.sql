-- Paid RC lookups are cached by plate so each plate is billed once per 30 days.
-- Only the edge function (service role) touches it; no policies means no client access.
create table if not exists public.rc_cache (
  plate      text primary key,
  data       jsonb not null,
  fetched_at timestamptz not null default now()
);
revoke all on public.rc_cache from public, anon, authenticated;
alter table public.rc_cache enable row level security;
