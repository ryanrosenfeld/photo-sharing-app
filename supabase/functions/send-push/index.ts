// Drains public.push_outbox to APNs (HTTP/2, token auth).
//
//   POST {"outbox_id": "<uuid>"}  send that notification (called by the dispatch_push trigger)
//   POST {}                       sweep every unsent row (schedule this to retry failures)
//
// Auth: header `x-push-secret` must equal PUSH_WEBHOOK_SECRET.
// Secrets (never in the repo): APNS_KEY_P8 (contents of the AuthKey_XXXX.p8), APNS_KEY_ID, APNS_TEAM_ID,
// optional APNS_BUNDLE_ID (default com.ryanrosenfeld.photoshare). Without APNS_KEY_P8 nothing is sent and rows stay queued.
// Local testing: APNS_HOST_SANDBOX / APNS_HOST_PRODUCTION override the Apple hosts (point them at a mock) and
// APNS_KEY_P8 may then be omitted if APNS_MOCK=1.
import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID") ?? "com.ryanrosenfeld.photoshare";
const HOSTS: Record<string, string> = {
  sandbox: Deno.env.get("APNS_HOST_SANDBOX") ?? "https://api.sandbox.push.apple.com",
  production: Deno.env.get("APNS_HOST_PRODUCTION") ?? "https://api.push.apple.com",
};
const MOCK = Deno.env.get("APNS_MOCK") === "1";
const MAX_ATTEMPTS = 5;

const b64url = (b: ArrayBuffer | string) =>
  btoa(typeof b === "string" ? b : String.fromCharCode(...new Uint8Array(b)))
    .replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");

let cachedJwt: { token: string; at: number } | null = null;
async function providerToken(): Promise<string> {
  if (MOCK) return "mock";
  if (cachedJwt && Date.now() - cachedJwt.at < 50 * 60_000) return cachedJwt.token; // APNs wants 20-60 min
  const pem = Deno.env.get("APNS_KEY_P8")!;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----|\s/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(JSON.stringify({ alg: "ES256", kid: Deno.env.get("APNS_KEY_ID") }));
  const claims = b64url(JSON.stringify({ iss: Deno.env.get("APNS_TEAM_ID"), iat: Math.floor(Date.now() / 1000) }));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`));
  cachedJwt = { token: `${head}.${claims}.${b64url(sig)}`, at: Date.now() };
  return cachedJwt.token;
}

type Row = { id: string; user_id: string; kind: string; title: string; body: string; data: Record<string, unknown>; attempts: number };

async function deliver(row: Row): Promise<void> {
  const { data: tokens } = await supabase.from("device_tokens").select("apns_token, environment").eq("user_id", row.user_id);
  if (!tokens?.length) { // nowhere to send: done, don't retry forever
    await supabase.from("push_outbox").update({ sent_at: new Date().toISOString() }).eq("id", row.id);
    return;
  }
  const { count } = await supabase.from("push_outbox").select("id", { count: "exact", head: true })
    .eq("user_id", row.user_id).eq("kind", "photo").is("read_at", null);
  const payload = {
    aps: { alert: { title: row.title, body: row.body }, sound: "default", badge: count ?? 1, "thread-id": row.kind },
    ...row.data, // routing ids only: kind, photo_id, friend_id. Never photo content.
  };
  const jwt = await providerToken();
  let ok = 0;
  for (const t of tokens) {
    const res = await fetch(`${HOSTS[t.environment] ?? HOSTS.production}/3/device/${t.apns_token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`, "apns-topic": BUNDLE_ID, "apns-push-type": "alert",
        "apns-priority": "10", "apns-collapse-id": row.id,
      },
      body: JSON.stringify(payload),
    });
    if (res.ok) ok++;
    else {
      const reason = (await res.json().catch(() => ({})))?.reason ?? res.status;
      console.log(`apns ${res.status} ${reason} for outbox ${row.id}`);
      if (res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered") {
        await supabase.from("device_tokens").delete().eq("apns_token", t.apns_token);
      }
    }
  }
  if (ok > 0) await supabase.from("push_outbox").update({ sent_at: new Date().toISOString(), attempts: row.attempts + 1 }).eq("id", row.id);
  else await supabase.from("push_outbox").update({ attempts: row.attempts + 1, sent_at: row.attempts + 1 >= MAX_ATTEMPTS ? new Date().toISOString() : null }).eq("id", row.id);
}

Deno.serve(async (req) => {
  const secret = Deno.env.get("PUSH_WEBHOOK_SECRET");
  if (!secret || req.headers.get("x-push-secret") !== secret) return new Response("forbidden", { status: 403 });
  if (!MOCK && !Deno.env.get("APNS_KEY_P8")) return new Response("APNS_KEY_P8 not configured; rows stay queued", { status: 503 });

  const { outbox_id } = await req.json().catch(() => ({}));
  let q = supabase.from("push_outbox").select("*").is("sent_at", null).lt("attempts", MAX_ATTEMPTS).order("created_at").limit(100);
  if (outbox_id) q = q.eq("id", outbox_id);
  const { data: rows, error } = await q;
  if (error) return new Response(error.message, { status: 500 });
  for (const row of rows ?? []) {
    try { await deliver(row as Row); } catch (e) { console.log(`deliver ${row.id} failed: ${e}`); }
  }
  return Response.json({ processed: rows?.length ?? 0 });
});
