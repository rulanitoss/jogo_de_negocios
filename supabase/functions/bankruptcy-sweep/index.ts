// ============================================================================
// MERCADO VIVO — Edge Function: bankruptcy-sweep
// Invocada pelo Supabase Scheduler (cron) ou manualmente com o token de
// serviço. Executa APENAS a função SQL transacional mv_bankruptcy_sweep():
// todo o motor financeiro vive na base de dados, nunca nesta function.
//
// Deploy:  supabase functions deploy bankruptcy-sweep --no-verify-jwt
// Secret:  supabase secrets set SUPABASE_SERVICE_ROLE_KEY=...
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) {
      throw new Error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY em falta.");
    }

    // Proteção mínima: exige o header shared secret configurado no scheduler.
    const expectedSecret = Deno.env.get("SWEEP_SHARED_SECRET");
    const providedSecret = req.headers.get("x-sweep-secret");
    if (expectedSecret && providedSecret !== expectedSecret) {
      return new Response(JSON.stringify({ error: "unauthorized" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // 1) Sweep de falências + expiração de listings/ofertas (transacional, SQL).
    const { data: sweep, error: sweepErr } = await admin.rpc(
      "mv_bankruptcy_sweep",
    );
    if (sweepErr) throw sweepErr;

    // 2) Atualização do índice de mercado e histórico de preços (SQL).
    const { error: indexErr } = await admin.rpc("mv_update_market_index");
    if (indexErr) throw indexErr;

    return new Response(
      JSON.stringify({ ok: true, sweep, ran_at: new Date().toISOString() }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (err) {
    console.error("[bankruptcy-sweep]", err);
    return new Response(JSON.stringify({ ok: false, error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
