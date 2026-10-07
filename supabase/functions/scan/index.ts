// The public side of Connect: everything a person who scanned a tag
// can do. Deployed with verify_jwt = false because scanners have no account;
// this function is the only path from them to the database and holds the
// service role key, so every check lives here.
//
// POST JSON { action, ... }:
//   lookup  { code }                              -> vehicle make/model/colour only
//   plate   { plate }                             -> { code } if a Connect car has that plate (plate-as-QR, OCR runs on-device)
//   alert   { code, plate_last4, kind, note?, photo?, lang? } -> { alert_id, token }
//   thread  { alert_id, token }                   -> { status, kind, note, messages, owner_status, medical }
//   reply   { alert_id, token, body }             -> { ok }
//   trip    { token }                             -> live position of a shared trip (web/trip.html)

import { createClient } from "npm:@supabase/supabase-js@2";
import { background, pushToUsers, vehicleAudience } from "../_shared/push.ts";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

// Salt for IP hashes. The local stack serves functions over plain http; a
// hosted project (https) must have SCAN_IP_SALT set, because with a public
// fallback salt the stored hashes could be reversed back to IP addresses.
const LOCAL = (Deno.env.get("SUPABASE_URL") ?? "").startsWith("http://");
const SALT = Deno.env.get("SCAN_IP_SALT") ?? (LOCAL ? "local-dev-salt" : null);

const LANGS = new Set(["en", "hi", "kn", "ta"]);
const KINDS = new Set(["blocking", "lights_on", "towing", "accident", "window_open", "other"]);
const CODE_RE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/;
const UUID_RE = /^[0-9a-f-]{36}$/;

const KIND_LABEL: Record<string, string> = {
  blocking: "Blocking a car",
  lights_on: "Lights are on",
  towing: "Being towed",
  window_open: "Window or door open",
  accident: "Accident or damage",
  other: "Message",
};

// A photo from the scan page, already shrunk in the browser to ~1280 px JPEG.
const PHOTO_MAX_BYTES = 700 * 1024;
const PHOTO_BUCKET = "alert-photos";
const PHOTO_DAYS = 7;

const LIMITS = {
  alertsPerIp10m: 5,
  alertsPerTag1h: 10,
  plateFailsPerIp10m: 5,
  repliesPerAlert: 20,
};

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

async function sha256(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Which x-forwarded-for entry is the real client depends on the proxies in
// front of the function: the leftmost entry is whatever the client sent, so
// trusting it lets a blocked sender rotate identities with one header.
// SCAN_IP_HOP counts from the right (1 = the address our nearest proxy saw).
// Verify it after every change of hosting; see README "Client IP". The value
// "first" trusts the client and exists only for local tests.
const IP_HOP = Deno.env.get("SCAN_IP_HOP") ?? "1";

function clientIp(req: Request) {
  const cf = req.headers.get("cf-connecting-ip");
  if (cf) return cf.trim();
  const hops = (req.headers.get("x-forwarded-for") ?? "").split(",").map((h) => h.trim()).filter(Boolean);
  if (hops.length === 0) return "unknown";
  if (IP_HOP === "first") return hops[0];
  const n = Math.max(1, parseInt(IP_HOP, 10) || 1);
  return hops[Math.max(0, hops.length - n)];
}

function minutesAgo(m: number) {
  return new Date(Date.now() - m * 60_000).toISOString();
}

function randomToken() {
  const b = new Uint8Array(24);
  crypto.getRandomValues(b);
  return btoa(String.fromCharCode(...b)).replace(/[+/=]/g, (c) => ({ "+": "-", "/": "_", "=": "" }[c]!));
}

// "Back by 6:30" set in the app. Only reaches someone who passed the plate
// check and sent an alert, never the bare lookup.
function ownerStatus(v: unknown) {
  const s = v as { back_at: string | null; away_note: string | null } | null;
  if (!s?.back_at || new Date(s.back_at).getTime() <= Date.now()) return null;
  return { back_at: s.back_at, note: s.away_note };
}

// Emergency info the owner opted to share, for accident alerts only.
function medical(v: unknown) {
  const m = v as { medical_share: boolean; blood_group: string | null; medical_note: string | null } | null;
  if (!m?.medical_share || (!m.blood_group && !m.medical_note)) return null;
  return { blood_group: m.blood_group, note: m.medical_note };
}

/** Decodes a base64 (or data: URL) JPEG, or null if it isn't one or is too big. */
function decodePhoto(v: unknown): Uint8Array | null {
  if (typeof v !== "string" || v.length === 0) return null;
  const b64 = v.replace(/^data:image\/jpeg;base64,/, "");
  if (b64.length > Math.ceil(PHOTO_MAX_BYTES / 3) * 4 + 4) return null;
  let bytes: Uint8Array;
  try {
    bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
  const jpeg = bytes.length > 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  return jpeg && bytes.length <= PHOTO_MAX_BYTES ? bytes : null;
}

// Photos older than a week are deleted, whether or not their alert still
// exists. Runs after alerts are sent, so it costs nothing extra to schedule.
async function sweepPhotos() {
  const cutoff = Date.now() - PHOTO_DAYS * 86_400_000;
  const { data: files } = await db.storage.from(PHOTO_BUCKET).list("", {
    limit: 100,
    sortBy: { column: "created_at", order: "asc" },
  });
  const old = (files ?? []).filter((f) => f.created_at && new Date(f.created_at).getTime() < cutoff).map((f) => f.name);
  if (old.length === 0) return;
  await db.storage.from(PHOTO_BUCKET).remove(old);
  await db.from("alerts").update({ photo_path: null }).in("photo_path", old);
}

type Tag = {
  code: string;
  owner: string;
  vehicle: { id: string; make: string; model: string; colour: string | null; reg_number: string };
};

async function activeTag(code: unknown): Promise<Tag | null> {
  if (typeof code !== "string") return null;
  const c = code.trim().toUpperCase();
  if (!CODE_RE.test(c)) return null;
  const { data } = await db
    .from("tags")
    .select("code, owner, active, vehicle:vehicles(id, make, model, colour, reg_number)")
    .eq("code", c)
    .maybeSingle();
  if (!data || !data.active || !data.vehicle) return null;
  return data as unknown as Tag;
}

async function scannerFor(alertId: unknown, token: unknown) {
  if (typeof alertId !== "string" || !UUID_RE.test(alertId) || typeof token !== "string") return null;
  const { data } = await db.from("alert_scanners").select("token_hash").eq("alert_id", alertId).maybeSingle();
  if (!data || data.token_hash !== (await sha256(token))) return null;
  return alertId;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (SALT === null) return json({ error: "not_configured" }, 503);
  if (req.method !== "POST") return json({ error: "method" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }
  const ipHash = await sha256(SALT + clientIp(req));

  switch (body.action) {
    case "lookup": {
      const tag = await activeTag(body.code);
      if (!tag) return json({ error: "tag_not_found" }, 404);
      const v = tag.vehicle;
      return json({ code: tag.code, make: v.make, model: v.model, colour: v.colour });
    }

    // Plate-as-QR: the phone read a plate with on-device OCR. Answers only with
    // the tag code of an active tag (the same thing a QR scan yields), so the
    // reply reveals "a Connect car exists", never a name or number. Failed
    // guesses count against the same per-IP budget as wrong plate digits, so
    // it can't be used to enumerate plates.
    case "plate": {
      const plate = String(body.plate ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      if (!/^[A-Z0-9]{6,11}$/.test(plate)) return json({ error: "tag_not_found" }, 404);
      const { count: fails } = await db.from("scan_failures").select("id", { count: "exact", head: true })
        .eq("ip_hash", ipHash).gte("created_at", minutesAgo(10));
      if ((fails ?? 0) >= LIMITS.plateFailsPerIp10m) return json({ error: "too_many_attempts" }, 429);
      // Anyone can register any plate, so a plate claimed by more than one
      // account is ambiguous. Answering "not found" is the safe failure: a
      // message must never be routed to someone who may have squatted it.
      const { data: vs } = await db.from("vehicles").select("id").eq("reg_number", plate).limit(5);
      const { data: tags } = vs?.length
        ? await db.from("tags").select("code").in("vehicle_id", vs.map((x) => x.id)).eq("active", true).limit(2)
        : { data: null };
      const t = tags?.length === 1 ? tags[0] : null;
      if (!t) {
        await db.from("scan_failures").insert({ ip_hash: ipHash, tag_code: null });
        return json({ error: "tag_not_found" }, 404);
      }
      return json({ code: t.code });
    }

    case "alert": {
      const tag = await activeTag(body.code);
      if (!tag) return json({ error: "tag_not_found" }, 404);
      if (typeof body.kind !== "string" || !KINDS.has(body.kind)) return json({ error: "bad_kind" }, 400);
      const note = typeof body.note === "string" && body.note.trim() ? body.note.trim().slice(0, 280) : null;
      const photo = body.photo == null || body.photo === "" ? null : decodePhoto(body.photo);
      if (body.photo && !photo) return json({ error: "bad_photo" }, 400);

      const { count: fails } = await db.from("scan_failures").select("id", { count: "exact", head: true })
        .eq("ip_hash", ipHash).gte("created_at", minutesAgo(10));
      if ((fails ?? 0) >= LIMITS.plateFailsPerIp10m) return json({ error: "too_many_attempts" }, 429);

      // Proves the sender is standing at the car (the plate is visible) rather
      // than holding a photo of the sticker that was shared online.
      const guess = String(body.plate_last4 ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");
      if (guess.length !== 4 || !tag.vehicle.reg_number.endsWith(guess)) {
        await db.from("scan_failures").insert({ ip_hash: ipHash, tag_code: tag.code });
        return json({ error: "plate_mismatch" }, 403);
      }

      const { data: blocked } = await db.from("blocked_scanners").select("owner")
        .eq("owner", tag.owner).eq("ip_hash", ipHash).maybeSingle();
      // Don't tell a blocked sender they're blocked; it only invites a new IP.
      if (blocked) return json({ alert_id: crypto.randomUUID(), token: randomToken() });

      const { count: recentByIp } = await db.from("alert_scanners")
        .select("alert_id, alerts!inner(created_at)", { count: "exact", head: true })
        .eq("ip_hash", ipHash).gte("alerts.created_at", minutesAgo(10));
      if ((recentByIp ?? 0) >= LIMITS.alertsPerIp10m) return json({ error: "rate_limited" }, 429);

      const { count: recentByTag } = await db.from("alerts").select("id", { count: "exact", head: true })
        .eq("tag_code", tag.code).gte("created_at", minutesAgo(60));
      if ((recentByTag ?? 0) >= LIMITS.alertsPerTag1h) return json({ error: "rate_limited" }, 429);

      const { data: alert, error } = await db.from("alerts").insert({
        tag_code: tag.code,
        vehicle_id: tag.vehicle.id,
        owner: tag.owner,
        kind: body.kind,
        note,
        scanner_lang: typeof body.lang === "string" && LANGS.has(body.lang) ? body.lang : "en",
      }).select("id").single();
      if (error || !alert) return json({ error: "insert_failed" }, 500);

      const token = randomToken();
      const { error: sErr } = await db.from("alert_scanners").insert({
        alert_id: alert.id,
        token_hash: await sha256(token),
        ip_hash: ipHash,
      });
      if (sErr) {
        await db.from("alerts").delete().eq("id", alert.id);
        return json({ error: "insert_failed" }, 500);
      }

      if (photo) {
        const path = `${alert.id}.jpg`;
        const { error: upErr } = await db.storage.from(PHOTO_BUCKET).upload(path, photo, { contentType: "image/jpeg" });
        // The alert matters more than the picture: keep it even if the upload fails.
        if (!upErr) await db.from("alerts").update({ photo_path: path }).eq("id", alert.id);
        else console.error("photo upload failed", upErr.message);
      }

      background((async () => {
        await pushToUsers(db, await vehicleAudience(db, tag.vehicle.id, tag.owner), {
          title: `${KIND_LABEL[body.kind as string]}: ${[tag.vehicle.make, tag.vehicle.model].join(" ")}`,
          body: note ?? "Someone near your car needs you. Tap to reply.",
          channel: "alerts",
          data: { alert_id: alert.id },
        });
        await sweepPhotos();
      })());
      return json({ alert_id: alert.id, token });
    }

    case "thread": {
      const id = await scannerFor(body.alert_id, body.token);
      // A blocked sender's fake alert id lands here too and just sees silence.
      if (!id) return json({ status: "open", messages: [] });
      const [{ data: alert }, { data: messages }] = await Promise.all([
        db.from("alerts")
          .select("status, blocked, kind, note, vehicle:vehicles(back_at, away_note, medical_share, blood_group, medical_note)")
          .eq("id", id).single(),
        db.from("alert_messages").select("id, sender, body, created_at").eq("alert_id", id).order("id", { ascending: true }),
      ]);
      if (!alert || alert.blocked) return json({ status: "open", messages: [] });
      return json({
        status: alert.status,
        kind: alert.kind,
        note: alert.note,
        messages,
        owner_status: ownerStatus(alert.vehicle),
        // Only for accidents, so paramedics or a helper can act on it.
        medical: alert.kind === "accident" ? medical(alert.vehicle) : null,
      });
    }

    case "reply": {
      const id = await scannerFor(body.alert_id, body.token);
      if (!id) return json({ ok: true });
      const text = typeof body.body === "string" ? body.body.trim().slice(0, 280) : "";
      if (!text) return json({ error: "empty" }, 400);
      const { data: alert } = await db.from("alerts").select("blocked, status, kind, vehicle_id, owner").eq("id", id).single();
      if (!alert || alert.blocked) return json({ ok: true });
      if (alert.status === "resolved") return json({ error: "resolved" }, 409);
      const { count } = await db.from("alert_messages").select("id", { count: "exact", head: true })
        .eq("alert_id", id).eq("sender", "scanner");
      if ((count ?? 0) >= LIMITS.repliesPerAlert) return json({ error: "rate_limited" }, 429);
      await db.from("alert_messages").insert({ alert_id: id, sender: "scanner", body: text });
      background((async () =>
        pushToUsers(db, await vehicleAudience(db, alert.vehicle_id, alert.owner), {
          title: `New message: ${KIND_LABEL[alert.kind] ?? "Message"}`,
          body: text,
          channel: "alerts",
          data: { alert_id: id },
        }))());
      return json({ ok: true });
    }

    case "trip": {
      if (typeof body.token !== "string" || !/^[0-9a-f]{36}$/.test(body.token)) return json({ error: "trip_not_found" }, 404);
      const { data: trip } = await db.from("trips")
        .select("started_at, ends_at, stopped, lat, lng, accuracy_m, speed_mps, trail, updated_at, vehicle:vehicles(make, model, colour)")
        .eq("token_hash", await sha256(body.token)).maybeSingle();
      if (!trip) return json({ error: "trip_not_found" }, 404);
      const ended = trip.stopped || new Date(trip.ends_at).getTime() <= Date.now();
      // Once a trip ends, its last position is no longer shared.
      if (ended) return json({ ended: true, started_at: trip.started_at });
      const v = trip.vehicle as unknown as { make: string; model: string; colour: string | null } | null;
      return json({
        ended: false,
        car: v ? [v.colour, v.make, v.model].filter(Boolean).join(" ") : null,
        started_at: trip.started_at,
        ends_at: trip.ends_at,
        updated_at: trip.updated_at,
        lat: trip.lat,
        lng: trip.lng,
        accuracy_m: trip.accuracy_m,
        speed_mps: trip.speed_mps,
        trail: trip.trail,
      });
    }

    default:
      return json({ error: "bad_action" }, 400);
  }
});
