// Vehicle RC (Registration Certificate) lookup through a licensed provider
// (Surepass). The key never leaves the server; the app calls this with its JWT.
//
// POST { plate } -> { plate, vehicle: { make, model, fuel, color, registered,
//                     insurance_upto, fitness_upto, category }, cached, mock? }
//
// The owner's name is never returned: the app needs the car, not the person.
// Results are cached 30 days in rc_cache. With no SUREPASS_TOKEN set it answers
// from a deterministic mock so the app can be built and demoed without a key.
//
// Secrets: SUREPASS_TOKEN, optional SUREPASS_BASE (default sandbox).

import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const TOKEN = Deno.env.get("SUREPASS_TOKEN");
const BASE = Deno.env.get("SUREPASS_BASE") ?? "https://sandbox.surepass.io";
const TTL_MS = 30 * 24 * 3600_000;
const PER_USER_HOURLY = 20;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

type Vehicle = {
  make: string | null; model: string | null; fuel: string | null; color: string | null;
  registered: string | null; insurance_upto: string | null; fitness_upto: string | null;
  category: string | null;
};

// Provider fields -> ours, dropping everything personal.
// deno-lint-ignore no-explicit-any
const slim = (d: any): Vehicle => ({
  make: d.maker_description ?? null,
  model: d.maker_model ?? null,
  fuel: d.fuel_type ?? null,
  color: d.color ?? null,
  registered: d.registration_date ?? null,
  insurance_upto: d.insurance_upto ?? null,
  fitness_upto: d.fit_up_to ?? null,
  category: d.vehicle_category ?? null,
});

const mock = (): Vehicle => ({
  make: "MARUTI SUZUKI INDIA LTD", model: "SWIFT VXI", fuel: "PETROL", color: "PEARL WHITE",
  registered: "2021-03-15", insurance_upto: "2027-03-14", fitness_upto: "2036-03-14", category: "LMV",
});

// Per-user budget, since every miss costs money. In-memory per isolate is enough
// to stop a runaway loop; the cache does the real saving.
const hits = new Map<string, number[]>();
function overBudget(uid: string): boolean {
  const now = Date.now();
  const recent = (hits.get(uid) ?? []).filter((t) => now - t < 3600_000);
  recent.push(now);
  hits.set(uid, recent);
  return recent.length > PER_USER_HOURLY;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: user } = await db.auth.getUser(jwt);
  if (!user?.user) return json({ error: "unauthorized" }, 401);

  let body: { plate?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const plate = String(body.plate ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
  if (!/^[A-Z]{2}[0-9]{1,2}[A-Z]{0,3}[0-9]{4}$/.test(plate)) return json({ error: "bad_plate" }, 400);

  const { data: hit } = await db.from("rc_cache").select("data, fetched_at").eq("plate", plate).maybeSingle();
  if (hit && Date.now() - new Date(hit.fetched_at).getTime() < TTL_MS) {
    return json({ plate, vehicle: hit.data, cached: true });
  }

  if (!TOKEN) return json({ plate, vehicle: mock(), cached: false, mock: true });

  if (overBudget(user.user.id)) return json({ error: "too_many_lookups" }, 429);

  let res: Response;
  try {
    res = await fetch(`${BASE}/api/v1/rc/rc-full`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
      body: JSON.stringify({ id_number: plate }),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    return json({ error: "provider_unreachable" }, 502);
  }
  const out = await res.json().catch(() => null);
  if (res.status === 404 || out?.status_code === 422 || out?.data == null) {
    return json({ error: "rc_not_found" }, 404);
  }
  if (!res.ok || !out?.success) return json({ error: "provider_error" }, 502);

  const vehicle = slim(out.data);
  await db.from("rc_cache").upsert({ plate, data: vehicle, fetched_at: new Date().toISOString() });
  return json({ plate, vehicle, cached: false });
});
