-- Account deletion (Play requires an in-app way). Every table that holds a
-- user's data references auth.users with on delete cascade, so removing the
-- auth row removes the car, tags, alerts, messages, family links, trips and
-- push tokens. Alert photos in storage are swept by the 7-day job.
create or replace function public.delete_my_account() returns void
language plpgsql volatile security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
