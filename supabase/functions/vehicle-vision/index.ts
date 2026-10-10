// Reads a car photo or an RC photo with the local vision model (Ollama on the
// laptop), so the owner types nothing. The photo is passed through and never stored.
//
// POST { kind: "car" | "rc", image: <base64 jpeg> }
//   car -> { plate, make, model, colour, body_type, fuel, features, condition }
//   rc  -> { plate, owner, make, model, fuel, colour, chassis, engine, registered, valid_upto }
// Every field is a string or null; null means "not visible", never a guess.
//
// Env: OLLAMA_URL (default http://host.docker.internal:11434), VISION_MODEL (default gemma4:e2b).

import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const OLLAMA = Deno.env.get("OLLAMA_URL") ?? "http://host.docker.internal:11434";
const MODEL = Deno.env.get("VISION_MODEL") ?? "gemma4:e2b";
const MAX_B64 = 1_500_000; // ~1.1 MB of jpeg; the app sends ~640 px
const PER_USER_HOURLY = 30;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

const str = { type: ["string", "null"] };
const schema = (keys: string[]) => ({
  type: "object",
  properties: Object.fromEntries(keys.map((k) => [k, str])),
  required: keys,
});

const KINDS: Record<string, { keys: string[]; prompt: string }> = {
  car: {
    keys: ["plate", "make", "model", "colour", "body_type", "fuel", "features", "condition"],
    prompt:
      "This is a photo of a car, taken to register it. Fill in: plate (the number plate exactly as printed, letters and digits only), " +
      "make (brand), model, colour (one plain word such as White, Silver, Grey, Black, Red, Blue, Brown, Green, Orange, Yellow), " +
      "body_type (hatchback, sedan, SUV, MUV, van, pickup, other), fuel (only if a badge or sticker shows it), " +
      "features (short list of things that identify this exact car: stickers, roof rails, alloys, dents, accessories), " +
      "condition (one short phrase). Use null for anything you cannot see. Never guess.",
  },
  rc: {
    keys: ["plate", "owner", "make", "model", "fuel", "colour", "chassis", "engine", "registered", "valid_upto"],
    prompt:
      "This is an Indian vehicle Registration Certificate (RC). Read it and fill in: plate (registration number, letters and digits only), " +
      "owner (registered owner's name), make (manufacturer), model, fuel, colour, chassis (chassis number), engine (engine number), " +
      "registered (date of registration, YYYY-MM-DD), valid_upto (registration validity, YYYY-MM-DD). " +
      "Copy exactly what is printed. Use null for anything you cannot read. Never guess.",
  },
};

const hits = new Map<string, number[]>();
function overBudget(uid: string): boolean {
  const now = Date.now();
  const recent = (hits.get(uid) ?? []).filter((t) => now - t < 3600_000);
  recent.push(now);
  hits.set(uid, recent);
  return recent.length > PER_USER_HOURLY;
}

const clean = (v: unknown): string | null => {
  if (Array.isArray(v)) v = v.join(", ");
  if (typeof v !== "string") return null;
  const s = v.trim();
  return s === "" || /^(null|none|n\/a|unknown|not visible)$/i.test(s) ? null : s.slice(0, 120);
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: user } = await db.auth.getUser(jwt);
  if (!user?.user) return json({ error: "unauthorized" }, 401);

  let body: { kind?: string; image?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const spec = KINDS[String(body.kind)];
  const image = String(body.image ?? "");
  if (!spec) return json({ error: "bad_kind" }, 400);
  if (!/^[A-Za-z0-9+/=]+$/.test(image) || image.length < 1000 || image.length > MAX_B64) return json({ error: "bad_image" }, 400);
  if (overBudget(user.user.id)) return json({ error: "too_many_reads" }, 429);

  let res: Response;
  try {
    res = await fetch(`${OLLAMA}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: MODEL,
        stream: false,
        keep_alive: "30m",
        format: schema(spec.keys),
        messages: [{ role: "user", content: spec.prompt, images: [image] }],
        options: { temperature: 0 },
      }),
      signal: AbortSignal.timeout(90_000),
    });
  } catch {
    return json({ error: "model_unreachable" }, 502);
  }
  if (!res.ok) return json({ error: "model_error" }, 502);
  const out = await res.json().catch(() => null);
  let parsed: Record<string, unknown> = {};
  try {
    parsed = JSON.parse(out?.message?.content ?? "{}");
  } catch {
    return json({ error: "model_bad_output" }, 502);
  }
  const fields = Object.fromEntries(spec.keys.map((k) => [k, clean(parsed[k])]));
  for (const k of ["registered", "valid_upto"]) {
    const m = String(fields[k] ?? "").match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/); // 15-03-2021 -> 2021-03-15
    if (m) fields[k] = `${m[3]}-${m[2].padStart(2, "0")}-${m[1].padStart(2, "0")}`;
  }
  if (fields.plate) fields.plate = String(fields.plate).toUpperCase().replace(/[^A-Z0-9]/g, "") || null;
  return json({ kind: body.kind, model: MODEL, fields });
});
