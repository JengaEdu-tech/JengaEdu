import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "Method not allowed" }), { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  try {
    const authHeader = req.headers.get("Authorization") || "";
    if (!authHeader.startsWith("Bearer ")) throw new Error("Authentication required");
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const solverUrl = Deno.env.get("TIMETABLE_SOLVER_URL");
    const solverKey = Deno.env.get("TIMETABLE_SOLVER_API_KEY");
    if (!solverUrl || !solverKey) throw new Error("The school timetable solver service is not configured");

    const userClient = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: authHeader } }, auth: { persistSession: false } });
    const { data: userData, error: userError } = await userClient.auth.getUser();
    if (userError || !userData.user) throw new Error("Invalid or expired session");

    const body = await req.json();
    const schoolId = String(body.school_id || "");
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(schoolId)) throw new Error("A valid school workspace is required");
    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
    const { data: membership, error: membershipError } = await admin
      .from("school_memberships")
      .select("role,status,schools!inner(status)")
      .eq("school_id", schoolId)
      .eq("user_id", userData.user.id)
      .maybeSingle();
    if (membershipError || !membership || membership.status !== "active" || membership.schools?.status !== "active") throw new Error("No active membership for this school workspace");
    if (!["school_admin", "headteacher", "deputy_headteacher"].includes(membership.role)) throw new Error("Your school role cannot generate or publish timetables");
    const { data: subscription, error: subscriptionError } = await admin
      .from("school_subscriptions")
      .select("status,trial_ends_at,current_period_end,grace_ends_at")
      .eq("school_id", schoolId)
      .maybeSingle();
    if (subscriptionError || !subscription) throw new Error("No active school subscription was found");
    const now = Date.now();
    const trialOk = subscription.status === "trialing" && subscription.trial_ends_at && new Date(subscription.trial_ends_at).getTime() + 7 * 86400000 > now;
    const activeOk = subscription.status === "active" && subscription.current_period_end && new Date(subscription.current_period_end).getTime() + 7 * 86400000 > now;
    const graceOk = subscription.status === "past_due" && subscription.grace_ends_at && new Date(subscription.grace_ends_at).getTime() > now;
    if (!(trialOk || activeOk || graceOk)) throw new Error("This school subscription does not currently allow timetable generation");

    const response = await fetch(new URL("/solve", solverUrl), {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Jenga-Solver-Key": solverKey },
      body: JSON.stringify(body),
    });
    const result = await response.json().catch(() => ({}));
    if (!response.ok) {
      const errorBody = { error: result.detail || result.error || "Solver request failed", solver_http_status: response.status };
      // Expected model infeasibility/input errors are returned as data so the UI
      // can show the solver's actionable explanation instead of a generic 500.
      return new Response(JSON.stringify(errorBody), { status: response.status === 422 ? 200 : response.status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    return new Response(JSON.stringify(result), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : "Unexpected solver error" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
