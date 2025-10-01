// Edge function to help with setting up Vault secrets for VOD processing
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

interface SetupRequest {
  action: "setup_vault" | "test_processing" | "check_status";
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const requestBody: SetupRequest = await req.json().catch(() => ({ action: "check_status" }));

    switch (requestBody.action) {
      case "setup_vault": {
        // Setup Vault secrets for the cron job
        console.log("Setting up Vault secrets...");

        // Store the Supabase URL and service role key in Vault
        const { error: urlError } = await supabase.rpc('vault.create_secret', {
          secret: SUPABASE_URL,
          name: 'supabase_url'
        }).single();

        if (urlError && !urlError.message.includes('duplicate')) {
          throw new Error(`Failed to store supabase_url: ${urlError.message}`);
        }

        const { error: keyError } = await supabase.rpc('vault.create_secret', {
          secret: SUPABASE_SERVICE_ROLE_KEY,
          name: 'service_role_key'
        }).single();

        if (keyError && !keyError.message.includes('duplicate')) {
          throw new Error(`Failed to store service_role_key: ${keyError.message}`);
        }

        return new Response(
          JSON.stringify({
            success: true,
            message: "Vault secrets configured successfully",
          }),
          {
            headers: { "Content-Type": "application/json" },
            status: 200,
          }
        );
      }

      case "test_processing": {
        // Manually trigger the processing function for testing
        console.log("Testing VOD processing...");

        const { data, error } = await supabase.rpc('manual_process_pending_vods', {
          max_vods: 3  // Process just 3 VODs for testing
        });

        if (error) {
          throw new Error(`Failed to trigger processing: ${error.message}`);
        }

        return new Response(
          JSON.stringify({
            success: true,
            message: "Processing triggered successfully",
            vods_processed: data || []
          }),
          {
            headers: { "Content-Type": "application/json" },
            status: 200,
          }
        );
      }

      case "check_status":
      default: {
        // Check the status of the cron job and recent processing
        console.log("Checking cron job status...");

        // Get cron job details
        const { data: cronJobs, error: cronError } = await supabase
          .from('cron.job')
          .select('*')
          .eq('jobname', 'process-pending-vods')
          .single();

        if (cronError) {
          console.error("Error fetching cron job:", cronError);
        }

        // Get recent job runs
        const { data: recentRuns, error: runsError } = await supabase
          .from('cron.job_run_details')
          .select('*')
          .order('start_time', { ascending: false })
          .limit(10);

        if (runsError) {
          console.error("Error fetching job runs:", runsError);
        }

        // Count VODs with pending chunks
        const { data: pendingStats, error: statsError } = await supabase.rpc('get_pending_vods_count');

        return new Response(
          JSON.stringify({
            success: true,
            cron_job: cronJobs || null,
            recent_runs: recentRuns || [],
            pending_vods: pendingStats || { count: 0 },
            message: cronJobs ? "Cron job is configured" : "Cron job not found"
          }),
          {
            headers: { "Content-Type": "application/json" },
            status: 200,
          }
        );
      }
    }
  } catch (error: any) {
    console.error("Schedule setup error:", error);
    return new Response(
      JSON.stringify({ error: error.message }),
      {
        headers: { "Content-Type": "application/json" },
        status: 500,
      }
    );
  }
});

/* Helper edge function for managing scheduled VOD processing

Usage:

1. Setup Vault secrets (run once):
curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/schedule-vod-processing' \
  --header "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  --header "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"action": "setup_vault"}'

2. Test processing manually:
curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/schedule-vod-processing' \
  --header "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  --header "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"action": "test_processing"}'

3. Check cron job status:
curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/schedule-vod-processing' \
  --header "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
  --header "apikey: $SUPABASE_SERVICE_ROLE_KEY" \
  --header 'Content-Type: application/json' \
  --data '{"action": "check_status"}'
*/