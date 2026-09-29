// Push for housing-society notices. The admin's app posts the notice through
// the REST API (RLS checks they're the admin), then calls this with
// { notice_id } so every member's phone gets it. Each notice is pushed once.
//
// Checks the caller's JWT itself, so it's safe even when served with
// --no-verify-jwt locally.

import { createClient } from "npm:@supabase/supabase-js@2";
import { pushToUsers } from "../_shared/push.ts";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: user } = await db.auth.getUser(jwt);
  if (!user?.user) return json({ error: "unauthorized" }, 401);

  let body: { notice_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  if (typeof body.notice_id !== "number") return json({ error: "bad_notice" }, 400);

  // Claim the notice atomically so a double tap can't push twice.
  const { data: notice } = await db.from("society_notices")
    .update({ pushed_at: new Date().toISOString() })
    .eq("id", body.notice_id)
    .eq("author", user.user.id)
    .is("pushed_at", null)
    .gte("created_at", new Date(Date.now() - 10 * 60_000).toISOString())
    .select("id, body, society_id, society:societies(name, admin)")
    .maybeSingle();
  const society = notice?.society as unknown as { name: string; admin: string } | undefined;
  if (!notice || society?.admin !== user.user.id) return json({ error: "not_found" }, 404);

  const { data: members } = await db.from("society_members").select("member").eq("society_id", notice.society_id);
  const audience = (members ?? []).map((m) => m.member as string).filter((m) => m !== user.user.id);
  await pushToUsers(db, audience, {
    title: society.name,
    body: notice.body,
    channel: "society",
    data: { society_id: notice.society_id, notice_id: String(notice.id) },
  });
  return json({ ok: true, recipients: audience.length });
});
