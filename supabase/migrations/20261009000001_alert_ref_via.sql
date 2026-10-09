-- A reference chosen by the sender, so the same alert lands once: a retry
-- after a lost reply (a basement, a lift), or two phones that both heard a
-- message passed on by sound and both deliver it.
alter table public.alerts add column client_ref text check (client_ref ~ '^[A-Za-z0-9:_-]{6,64}$');
create unique index alerts_client_ref_idx on public.alerts (tag_code, client_ref) where client_ref is not null;

-- How the alert reached Connect. 'sound' means another phone carried it out
-- of a place with no signal, so the sender may never see a reply.
alter table public.alerts add column via text not null default 'tag' check (via in ('tag', 'sound'));
