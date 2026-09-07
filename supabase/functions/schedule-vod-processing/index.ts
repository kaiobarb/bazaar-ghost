import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { supabase, verifySecretKey } from "../_shared/supabase.ts";
import { corsHeaders } from "../_shared/cors.ts";

/** Scheduling is owned by database migrations; this endpoint inspects or triggers it. */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  if (!verifySecretKey(req)) {
    return new Response("Unauthorized", { status: 401 });
  }
  try {
    const { action = "check_status" } = await req.json();
    if (action === "test_processing") {
      const { data, error } = await supabase.rpc("process_pending_vods", {
        max_vods: 3,
      });
      if (error) throw new Error(error.message);
      return Response.json({ success: true, vods_processed: data }, {
        headers: corsHeaders,
      });
    }
    if (action !== "check_status") {
      return Response.json({
        error:
          "Use check_status or test_processing. Configure Vault secrets through local SQL and migrations.",
      }, { status: 400, headers: corsHeaders });
    }
    const { data, error } = await supabase.rpc("get_pending_vods_count");
    if (error) throw new Error(error.message);
    return Response.json({ success: true, pending_vods: data }, {
      headers: corsHeaders,
    });
  } catch (error: any) {
    return Response.json({ error: error.message }, {
      status: 500,
      headers: corsHeaders,
    });
  }
});
