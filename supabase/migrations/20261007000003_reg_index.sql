-- Plate-as-QR looks a car up by plate alone; unique (owner, reg_number) can't serve that.
create index if not exists vehicles_reg_number_idx on public.vehicles (reg_number);
