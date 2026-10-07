-- "The owner has seen your message": set when the owner opens the thread, so
-- the person waiting at the car knows someone is on it before any reply.
alter table public.alerts add column seen_at timestamptz;
grant update (seen_at) on public.alerts to authenticated;
