-- Plate-as-QR lookups that miss have no tag to attribute the failure to.
alter table public.scan_failures alter column tag_code drop not null;
