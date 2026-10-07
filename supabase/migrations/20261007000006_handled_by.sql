-- Who in the family took an alert ("Priya is on the way"), so two people do
-- not both reply or both rush to the car. Never shown to the person at the car.
alter table public.alerts add column handled_by uuid references auth.users(id) on delete set null;
grant update (handled_by) on public.alerts to authenticated;
