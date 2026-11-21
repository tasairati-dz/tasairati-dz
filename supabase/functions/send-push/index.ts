// Supabase Edge Function: send-push
// النشر: supabase functions deploy send-push
// الأسرار: supabase secrets set ONESIGNAL_APP_ID=... ONESIGNAL_REST_API_KEY=...
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const authHeader = req.headers.get("Authorization") ?? "";
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return new Response("Unauthorized", { status: 401, headers: cors });

    const { user_ids, title, body, data } = await req.json();
    const ids = (Array.isArray(user_ids) ? user_ids : []).map(String).slice(0, 2000);
    if (!ids.length || !title) {
      return new Response(JSON.stringify({ error: "missing fields" }), { status: 400, headers: cors });
    }

    const res = await fetch("https://api.onesignal.com/notifications?c=push", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Key ${Deno.env.get("ONESIGNAL_REST_API_KEY")}`,
      },
      body: JSON.stringify({
        app_id: Deno.env.get("ONESIGNAL_APP_ID"),
        target_channel: "push",
        include_aliases: { external_id: ids },
        headings: { ar: String(title).slice(0, 120), en: String(title).slice(0, 120) },
        contents: { ar: String(body ?? "").slice(0, 300), en: String(body ?? "").slice(0, 300) },
        data: data ?? {},
      }),
    });

    return new Response(await res.text(), {
      status: res.status,
      headers: { ...cors, "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: cors });
  }
});
