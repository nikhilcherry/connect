-- Trigger functions are reachable as /rest/v1/rpc/<name> unless revoked. They
-- can't do anything when called directly, but keep the API surface to what the
-- app actually calls (flagged by the Supabase security advisor).
revoke all on function public.touch_alert() from public, anon, authenticated;
revoke all on function public.guard_reg_number() from public, anon, authenticated;
revoke all on function public.gen_tag_code() from public, anon;
