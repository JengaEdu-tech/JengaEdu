// Secure JengaEdu staff invitation sender.
// Deploy as: supabase functions deploy invite-staff
// Required Supabase function secrets are supplied automatically by Supabase:
// SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status, headers: { ...cors, "Content-Type": "application/json" },
});
const env = (key: string) => Deno.env.get(key) || "";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  try {
    const authorization = req.headers.get("Authorization") || "";
    const userToken = authorization.replace(/^Bearer\s+/i, "");
    const url = env("SUPABASE_URL"), anon = env("SUPABASE_ANON_KEY"), service = env("SUPABASE_SERVICE_ROLE_KEY");
    if (!userToken) return json({ error: "Sign in before sending an invitation." }, 401);
    if (!url || !anon || !service) return json({ error: "Supabase function secrets are incomplete." }, 500);

    const auth = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anon, Authorization: `Bearer ${userToken}` } });
    if (!auth.ok) return json({ error: "Your session is invalid or expired." }, 401);
    const caller = await auth.json();
    const body = await req.json();
    const schoolId = String(body.schoolId || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const role = String(body.role || "").trim();
    const requestedRedirect = String(body.redirectTo || "").trim();
    const allowedRedirect = env("JENGAEDU_WORKSPACE_URL") || "https://jengaedu-tech.github.io/JengaEdu/workspace.html";
    const allowedTarget = new URL(allowedRedirect);
    const requestedTarget = new URL(requestedRedirect || allowedRedirect);
    const redirectTo = requestedTarget.origin === allowedTarget.origin && requestedTarget.pathname === allowedTarget.pathname
      ? allowedTarget.toString() : "";
    const allowedRoles = ["school_admin", "teacher", "staff", "bursar", "accountant", "librarian"];
    if (!schoolId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ error: "A school and valid email address are required." }, 400);
    if (!allowedRoles.includes(role)) return json({ error: "The selected role is not allowed." }, 400);
    if (!redirectTo) return json({ error: "The invitation return address does not match the configured JengaEdu workspace URL." }, 400);

    // The database RPC enforces school-admin / platform-admin authorization.
    const created = await fetch(`${url}/rest/v1/rpc/create_school_invitation`, {
      method: "POST", headers: { apikey: anon, Authorization: `Bearer ${userToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({ p_school_id: schoolId, p_email: email, p_role: role }),
    });
    const invitationId = await created.json().catch(() => null);
    if (!created.ok || !invitationId) return json({ error: "Invitation was not authorized or could not be created." }, created.status || 400);

    const lookup = await fetch(`${url}/rest/v1/school_invitations?id=eq.${encodeURIComponent(String(invitationId))}&select=token,email,role,expires_at`, {
      headers: { apikey: anon, Authorization: `Bearer ${userToken}` },
    });
    const rows = await lookup.json().catch(() => []);
    const invitation = Array.isArray(rows) ? rows[0] : null;
    if (!lookup.ok || !invitation?.token) return json({ error: "Invitation was created but its secure link could not be prepared." }, 500);

    const target = new URL(redirectTo);
    target.searchParams.set("invitation", invitation.token);
    const inviteUrl = new URL(`${url}/auth/v1/invite`);
    inviteUrl.searchParams.set("redirect_to", target.toString());
    const sent = await fetch(inviteUrl.toString(), {
      method: "POST",
      headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json" },
      body: JSON.stringify({ email, data: { full_name: "JengaEdu invited staff", school_id: schoolId, school_role: role, invitation_id: invitationId } }),
    });
    if (!sent.ok) {
      const detail = await sent.text();
      // Do not leave an apparently usable pending invitation if email delivery failed.
      await fetch(`${url}/rest/v1/school_invitations?id=eq.${encodeURIComponent(String(invitationId))}`, {
        method: "PATCH", headers: { apikey: anon, Authorization: `Bearer ${userToken}`, "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({ status: "cancelled" }),
      });
      return json({ error: `Supabase could not send the invitation email: ${detail.slice(0, 240)}` }, sent.status || 502);
    }
    return json({ ok: true, invitationId, email, role, expiresAt: invitation.expires_at, message: "Invitation email submitted to Supabase Auth." });
  } catch (error) {
    return json({ error: String((error as Error)?.message || error).slice(0, 300) }, 500);
  }
});
