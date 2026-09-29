// Firebase Cloud Messaging (HTTP v1) sender, shared by `scan` and `notify`.
// Free and unlimited on Firebase's Spark plan. Does nothing until the
// FCM_SERVICE_ACCOUNT secret holds a service-account JSON key:
//   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"

import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

type ServiceAccount = { client_email: string; private_key: string; project_id: string };

const SA: ServiceAccount | null = (() => {
  const raw = Deno.env.get("FCM_SERVICE_ACCOUNT");
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    console.error("FCM_SERVICE_ACCOUNT is not valid JSON; push disabled");
    return null;
  }
})();

export const pushEnabled = SA !== null;

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/[+/=]/g, (c) => ({ "+": "-", "/": "_", "=": "" }[c]!));
const enc = new TextEncoder();

let cached: { token: string; exp: number } | null = null;

// Google OAuth access token from a self-signed RS256 JWT, cached for its hour.
async function accessToken(sa: ServiceAccount) {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.exp - 60 > now) return cached.token;
  const header = b64url(enc.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = b64url(enc.encode(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  })));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, enc.encode(`${header}.${claims}`)));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${b64url(sig)}`,
    }),
  });
  const j = await res.json();
  if (!res.ok || !j.access_token) throw new Error(`fcm auth failed: ${res.status}`);
  cached = { token: j.access_token, exp: now + (j.expires_in ?? 3600) };
  return cached.token;
}

export type PushMessage = {
  title: string;
  body: string;
  /** Android notification channel, matching the app's local channels. */
  channel: "alerts" | "society";
  data: Record<string, string>;
};

/** Sends to every device of these users. Dead tokens are removed. */
export async function pushToUsers(db: SupabaseClient, userIds: string[], msg: PushMessage) {
  if (!SA || userIds.length === 0) return;
  const { data: rows } = await db.from("push_tokens").select("token").in("user_id", [...new Set(userIds)]);
  if (!rows?.length) return;
  const auth = await accessToken(SA);
  await Promise.all(rows.map(async ({ token }) => {
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${SA.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${auth}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: msg.title, body: msg.body },
          data: msg.data,
          android: { priority: "high", notification: { channel_id: msg.channel } },
        },
      }),
    });
    if (res.ok) return;
    const err = await res.json().catch(() => ({}));
    const code = err?.error?.details?.find((d: { errorCode?: string }) => d.errorCode)?.errorCode;
    if (res.status === 404 || code === "UNREGISTERED") {
      await db.from("push_tokens").delete().eq("token", token);
    } else {
      console.error("fcm send failed", res.status, code);
    }
  }));
}

/** The owner plus every family member of a car. */
export async function vehicleAudience(db: SupabaseClient, vehicleId: string, owner: string) {
  const { data } = await db.from("vehicle_members").select("member").eq("vehicle_id", vehicleId);
  return [owner, ...(data ?? []).map((r) => r.member as string)];
}

/** Keeps work running after the response is sent, where the runtime allows. */
export function background(p: Promise<unknown>) {
  const done = p.catch((e) => console.error("background task failed", e));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(done);
}
