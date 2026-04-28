// Edge Function: invite-user
// Lädt einen neuen Nutzer per Supabase Auth Invite ein.
// Aufruf nur durch authentifizierte Nutzer (JWT-Check).
// Service-Role-Key wird als Secret SERVICE_ROLE_KEY erwartet.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY");
const SERVICE_ROLE_KEY = Deno.env.get("SERVICE_ROLE_KEY");

console.log("[invite-user] boot", {
  has_url: !!SUPABASE_URL,
  has_anon: !!SUPABASE_ANON_KEY,
  has_service: !!SERVICE_ROLE_KEY,
  service_len: SERVICE_ROLE_KEY?.length ?? 0,
});

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

Deno.serve(async (req) => {
  console.log("[invite-user] request", req.method, req.url);
  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
    if (req.method !== "POST") return json(405, { ok: false, error: "Method not allowed" });

    if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SERVICE_ROLE_KEY) {
      console.error("[invite-user] missing env", {
        has_url: !!SUPABASE_URL,
        has_anon: !!SUPABASE_ANON_KEY,
        has_service: !!SERVICE_ROLE_KEY,
      });
      return json(500, { ok: false, error: "Server misconfigured (missing env)" });
    }

    const authHeader = req.headers.get("Authorization") ?? "";
    const jwt = authHeader.replace(/^Bearer\s+/i, "");
    if (!jwt) {
      console.warn("[invite-user] no auth header");
      return json(401, { ok: false, error: "Missing Authorization header" });
    }

    // Auth-Check: ist der Aufrufer ein eingeloggter User?
    const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) {
      console.warn("[invite-user] auth check failed", userErr?.message);
      return json(401, { ok: false, error: "Not authenticated" });
    }
    console.log("[invite-user] caller", userData.user.email);

    let email: string;
    let bodyRaw: unknown;
    try {
      bodyRaw = await req.json();
      email = String((bodyRaw as { email?: unknown })?.email ?? "").trim().toLowerCase();
    } catch (e) {
      console.warn("[invite-user] body parse failed", String(e));
      return json(400, { ok: false, error: "Invalid JSON body" });
    }
    if (!email || !EMAIL_RE.test(email)) {
      console.warn("[invite-user] invalid email", { email, body: bodyRaw });
      return json(400, { ok: false, error: "Invalid email" });
    }
    console.log("[invite-user] inviting", email);

    // Admin-Client mit Service-Role darf inviteUserByEmail.
    const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
    });
    const { data: inviteData, error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email);
    if (inviteErr) {
      console.error("[invite-user] invite failed", {
        message: inviteErr.message,
        status: (inviteErr as { status?: number }).status,
        name: inviteErr.name,
      });
      return json(400, { ok: false, error: inviteErr.message });
    }

    console.log("[invite-user] invite ok", inviteData?.user?.id);
    return json(200, { ok: true, email });
  } catch (e) {
    console.error("[invite-user] unhandled", e instanceof Error ? e.stack : String(e));
    return json(500, { ok: false, error: e instanceof Error ? e.message : String(e) });
  }
});
