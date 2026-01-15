// Process VOD - Find and trigger processing for all pending chunks of a VOD
// Also handles Twitch EventSub stream.offline webhooks
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import {
  fetchAndUpsertVods,
  supabase,
  verifySecretKey,
} from "../_shared/supabase.ts";
import { verifyEventSubSignature } from "../_shared/twitch.ts";
import { log, recordCounter } from "../_shared/telemetry.ts";

const GITHUB_TOKEN = Deno.env.get("GITHUB_TOKEN")!;
const GITHUB_OWNER = "kaiobarb";
const GITHUB_REPO = "bazaar-ghost";
const TWITCH_EVENTSUB_SECRET = Deno.env.get("TWITCH_EVENTSUB_SECRET")!;

interface ProcessVodRequest {
  vod_id?: number | string; // Can be bigint (internal) or string
  source_id?: string; // Twitch VOD ID
  dry_run?: boolean; // If true, only return what would be processed
}

interface ProcessVodResponse {
  success: boolean;
  message: string;
  vod_id?: number;
  source_id?: string;
  chunks_found?: number;
  chunk_uuids?: string[];
  github_run_url?: string;
  error?: string;
}

// EventSub payload types
interface EventSubPayload {
  subscription: {
    id: string;
    type: string;
    status: string;
    condition: Record<string, string>;
  };
  event?: {
    broadcaster_user_id: string;
    broadcaster_user_login: string;
    broadcaster_user_name: string;
  };
  challenge?: string;
}

async function triggerGithubWorkflow(
  vodId: string,
  chunkUuids: string[],
  oldTemplates: boolean,
  sfotProfile: string,
  environment: string,
): Promise<string | null> {
  const workflowDispatchUrl =
    `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/process-vod.yml/dispatches`;

  console.log(
    `Triggering workflow for VOD ${vodId} with ${chunkUuids.length} chunks (old_templates: ${oldTemplates}, environment: ${environment})`,
  );

  const branch = environment === "dev" ? "dev" : "main";

  const response = await fetch(workflowDispatchUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ref: branch,
      inputs: {
        vod_id: vodId,
        chunk_uuids: JSON.stringify(chunkUuids), // Pass as JSON string
        old_templates: oldTemplates.toString(), // Pass as string
        sfot_profile: sfotProfile, // Pass profile as JSON string
        environment: environment, // Pass environment selection
      },
    }),
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(
      `GitHub workflow dispatch failed: ${response.status} ${response.statusText}`,
      errorText,
    );
    throw new Error(
      `GitHub API error: ${response.status} ${response.statusText} - ${errorText}`,
    );
  }

  // GitHub API returns 204 No Content on success
  // Construct the Actions page URL for the workflow
  const actionsUrl =
    `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/process-vod.yml`;
  return actionsUrl;
}

async function getPendingChunksForVod(
  vodId?: number | string,
  sourceId?: string,
) {
  // Use the SQL function we created
  const { data, error } = await supabase.rpc("get_pending_chunks_for_vod", {
    p_vod_id: vodId ? Number(vodId) : null,
    p_source_id: sourceId || null,
  });

  if (error) {
    console.error("Error fetching pending chunks:", error);
    throw new Error(`Database error: ${error.message}`);
  }

  return data || [];
}

/**
 * Handle Twitch EventSub webhook requests
 */
async function handleEventSubWebhook(
  req: Request,
  messageType: string,
): Promise<Response> {
  const body = await req.text();
  const messageId = req.headers.get("Twitch-Eventsub-Message-Id");
  const timestamp = req.headers.get("Twitch-Eventsub-Message-Timestamp");
  const signature = req.headers.get("Twitch-Eventsub-Message-Signature");

  // Record webhook received metric
  recordCounter("eventsub.webhook.received", 1, { message_type: messageType });

  // Validate required headers
  if (!messageId || !timestamp || !signature) {
    log("warn", "Missing EventSub headers", { messageId, timestamp, signature });
    return new Response("Missing required headers", { status: 400 });
  }

  // Verify signature
  if (!TWITCH_EVENTSUB_SECRET) {
    log("error", "TWITCH_EVENTSUB_SECRET not configured");
    return new Response("Server configuration error", { status: 500 });
  }

  const isValid = await verifyEventSubSignature(
    messageId,
    timestamp,
    body,
    signature,
    TWITCH_EVENTSUB_SECRET,
  );

  if (!isValid) {
    recordCounter("eventsub.signature.invalid", 1);
    log("warn", "Invalid EventSub signature", { messageId });
    return new Response("Invalid signature", { status: 403 });
  }

  const payload: EventSubPayload = JSON.parse(body);

  // Handle webhook callback verification (challenge)
  if (messageType === "webhook_callback_verification") {
    log("info", "EventSub challenge verification", {
      subscription_type: payload.subscription.type,
    });
    return new Response(payload.challenge, {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    });
  }

  // Handle subscription revocation
  if (messageType === "revocation") {
    log("warn", "EventSub subscription revoked", {
      subscription_id: payload.subscription.id,
      subscription_type: payload.subscription.type,
      status: payload.subscription.status,
    });
    recordCounter("eventsub.revocation", 1, {
      type: payload.subscription.type,
      status: payload.subscription.status,
    });
    return new Response(null, { status: 204 });
  }

  // Handle notification
  if (messageType === "notification") {
    if (payload.subscription.type === "stream.offline" && payload.event) {
      await processStreamOffline(payload.event);
    } else {
      log("info", "Received unsupported EventSub notification", {
        type: payload.subscription.type,
      });
    }
  }

  return new Response(null, { status: 204 });
}

/**
 * Process stream.offline event - fetch latest VOD and trigger processing
 */
async function processStreamOffline(event: {
  broadcaster_user_id: string;
  broadcaster_user_login: string;
  broadcaster_user_name: string;
}): Promise<void> {
  const { broadcaster_user_id, broadcaster_user_login, broadcaster_user_name } =
    event;

  log("info", "Processing stream.offline event", {
    user_id: broadcaster_user_id,
    login: broadcaster_user_login,
    name: broadcaster_user_name,
  });

  // 1. Look up streamer in database (try by ID first, then by login)
  let streamer: {
    id: number;
    login: string;
    display_name: string;
    processing_enabled: boolean;
  } | null = null;

  // Try by ID first
  const { data: streamerById } = await supabase
    .from("streamers")
    .select("id, login, display_name, processing_enabled")
    .eq("id", parseInt(broadcaster_user_id))
    .single();

  if (streamerById) {
    streamer = streamerById;
  } else {
    // Fallback to login lookup (useful for testing with Twitch CLI)
    const { data: streamerByLogin } = await supabase
      .from("streamers")
      .select("id, login, display_name, processing_enabled")
      .eq("login", broadcaster_user_login)
      .single();
    streamer = streamerByLogin;
  }

  if (!streamer) {
    recordCounter("eventsub.stream_offline.skipped", 1, { reason: "not_found" });
    log("info", "Streamer not found in database", {
      user_id: broadcaster_user_id,
      login: broadcaster_user_login,
    });
    return;
  }

  // 2. Check if processing is enabled
  if (!streamer.processing_enabled) {
    recordCounter("eventsub.stream_offline.skipped", 1, { reason: "disabled" });
    log("info", "Processing disabled for streamer", {
      streamer_id: streamer.id,
      login: streamer.login,
    });
    return;
  }

  // 3. Fetch latest VOD with chapters and upsert to database
  log("info", "Fetching latest VOD for streamer", {
    streamer_id: streamer.id,
    login: streamer.login,
  });

  const { vodsUpserted, bazaarSegments, upsertedVodIds } =
    await fetchAndUpsertVods(
      streamer.id,
      streamer.login,
      1, // Only fetch the latest VOD
    );

  if (vodsUpserted === 0 || upsertedVodIds.length === 0) {
    recordCounter("eventsub.stream_offline.skipped", 1, { reason: "no_bazaar" });
    log("info", "No Bazaar VOD found for streamer", {
      streamer_id: streamer.id,
      login: streamer.login,
    });
    return;
  }

  const vodSourceId = upsertedVodIds[0];

  recordCounter("eventsub.stream_offline.processed", 1, {
    streamer: streamer.login,
  });
  log("info", "Upserted VOD for streamer", {
    streamer_id: streamer.id,
    login: streamer.login,
    vod_source_id: vodSourceId,
    bazaar_segments: bazaarSegments,
  });

  // 4. Trigger processing for the new VOD
  try {
    const chunks = await getPendingChunksForVod(undefined, vodSourceId);

    if (chunks.length === 0) {
      log("info", "No pending chunks for new VOD", {
        vod_source_id: vodSourceId,
      });
      return;
    }

    const chunkUuids = chunks.map((chunk: any) => chunk.chunk_id);
    const actualVodId = chunks[0].vod_id;

    // Fetch VOD's published_at date and streamer's profile
    const { data: vodData, error: vodError } = await supabase
      .from("vods")
      .select("published_at, streamer_id, streamers!inner(sfot_profile_id)")
      .eq("id", actualVodId)
      .single();

    if (vodError) {
      log("error", "Failed to fetch VOD data", {
        vod_id: actualVodId,
        error: vodError.message,
      });
      return;
    }

    // Check if VOD was published on or before August 12, 2025
    const cutoffDate = new Date("2025-08-12T00:00:00Z");
    const vodPublishedAt = new Date(vodData.published_at);
    const useOldTemplates = vodPublishedAt <= cutoffDate;

    // Fetch SFOT profile
    const sfotProfileId = vodData.streamers.sfot_profile_id;
    const { data: profileData, error: profileError } = await supabase
      .from("sfot_profiles")
      .select("*")
      .eq("id", sfotProfileId)
      .single();

    if (profileError) {
      log("error", "Failed to fetch SFOT profile", {
        profile_id: sfotProfileId,
        error: profileError.message,
      });
      return;
    }

    const sfotProfileJson = JSON.stringify(profileData);
    const environment = Deno.env.get("ENV") || "production";

    // Update chunks to 'queued' status
    const { error: updateError } = await supabase
      .from("chunks")
      .update({ status: "queued" })
      .in("id", chunkUuids);

    if (updateError) {
      log("error", "Failed to update chunks to queued", {
        error: updateError.message,
      });
      return;
    }

    // Trigger GitHub workflow
    const githubRunUrl = await triggerGithubWorkflow(
      vodSourceId,
      chunkUuids,
      useOldTemplates,
      sfotProfileJson,
      environment,
    );

    recordCounter("process_vod.triggered", 1, {
      source: "eventsub",
      streamer: streamer.login,
    });
    log("info", "Triggered processing for stream.offline VOD", {
      vod_source_id: vodSourceId,
      chunks_count: chunks.length,
      github_url: githubRunUrl,
    });
  } catch (error: any) {
    log("error", "Failed to trigger processing for stream.offline VOD", {
      vod_source_id: vodSourceId,
      error: error.message,
    });
  }
}

/**
 * Handle internal API requests (existing flow)
 */
async function handleInternalRequest(req: Request): Promise<Response> {
  try {
    // Handle CORS preflight
    if (req.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers":
            "authorization, x-client-info, apikey, content-type",
        },
      });
    }

    // Verify secret key authentication (after CORS to allow preflight)
    if (!verifySecretKey(req)) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        {
          headers: { "Content-Type": "application/json" },
          status: 401,
        },
      );
    }

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const requestBody: ProcessVodRequest = await req.json().catch(() => ({}));
    const { vod_id, source_id, dry_run = false } = requestBody;

    console.log(
      `Process VOD request - vod_id: ${vod_id}, source_id: ${source_id}, dry_run: ${dry_run}`,
    );

    // Validate input
    if (!vod_id && !source_id) {
      const response: ProcessVodResponse = {
        success: false,
        message: "Must provide either vod_id or source_id",
        error: "Missing required parameter",
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 400,
      });
    }

    // Get pending chunks for the VOD
    const chunks = await getPendingChunksForVod(vod_id, source_id);

    if (chunks.length === 0) {
      const response: ProcessVodResponse = {
        success: true,
        message: "No pending chunks found for this VOD",
        vod_id: vod_id ? Number(vod_id) : undefined,
        source_id: source_id,
        chunks_found: 0,
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Extract chunk UUIDs
    const chunkUuids = chunks.map((chunk: any) => chunk.chunk_id);
    const actualVodId = chunks[0].vod_id;
    const actualSourceId = chunks[0].source_id;

    console.log(
      `Found ${chunks.length} pending chunks for VOD ${actualVodId} (${actualSourceId})`,
    );

    // Fetch VOD's published_at date and streamer's profile to determine processing settings
    const { data: vodData, error: vodError } = await supabase
      .from("vods")
      .select("published_at, streamer_id, streamers!inner(sfot_profile_id)")
      .eq("id", actualVodId)
      .single();

    if (vodError) {
      console.error("Error fetching VOD data:", vodError);
      throw new Error(`Failed to fetch VOD data: ${vodError.message}`);
    }

    // Check if VOD was published on or before August 12, 2025
    const cutoffDate = new Date("2025-08-12T00:00:00Z");
    const vodPublishedAt = new Date(vodData.published_at);
    const useOldTemplates = vodPublishedAt <= cutoffDate;

    console.log(
      `VOD published at: ${vodData.published_at}, cutoff: ${cutoffDate.toISOString()}, use old templates: ${useOldTemplates}`,
    );

    // Fetch the streamer's SFOT profile
    const sfotProfileId = vodData.streamers.sfot_profile_id;
    const { data: profileData, error: profileError } = await supabase
      .from("sfot_profiles")
      .select("*")
      .eq("id", sfotProfileId)
      .single();

    if (profileError) {
      console.error("Error fetching SFOT profile:", profileError);
      throw new Error(`Failed to fetch SFOT profile: ${profileError.message}`);
    }

    // Serialize profile as JSON string for passing to GitHub Actions
    const sfotProfileJson = JSON.stringify(profileData);
    console.log(`Using SFOT profile: ${profileData.profile_name}`);

    // Get environment from ENV environment variable (set via .env or .env.dev)
    const environment = Deno.env.get("ENV") || "production";
    console.log(`Using environment: ${environment}`);

    // If dry run, just return what would be processed
    if (dry_run) {
      const response: ProcessVodResponse = {
        success: true,
        message:
          `Dry run: Would process ${chunks.length} chunks (old_templates: ${useOldTemplates})`,
        vod_id: actualVodId,
        source_id: actualSourceId,
        chunks_found: chunks.length,
        chunk_uuids: chunkUuids,
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    }

    // Update chunks to 'queued' status before triggering GitHub workflow
    console.log(`Updating ${chunks.length} chunks to 'queued' status`);
    const { error: updateError } = await supabase
      .from("chunks")
      .update({ status: "queued" })
      .in("id", chunkUuids);

    if (updateError) {
      console.error("Error updating chunks to queued status:", updateError);
      throw new Error(
        `Failed to update chunks to queued status: ${updateError.message}`,
      );
    }

    // Trigger GitHub workflow with all chunk UUIDs
    const githubRunUrl = await triggerGithubWorkflow(
      actualSourceId,
      chunkUuids,
      useOldTemplates,
      sfotProfileJson,
      environment,
    );

    recordCounter("process_vod.triggered", 1, { source: "internal" });

    console.log(
      `Successfully triggered GitHub workflow for VOD ${actualVodId} with ${chunks.length} chunks`,
    );

    const response: ProcessVodResponse = {
      success: true,
      message:
        `Successfully triggered processing for ${chunks.length} chunks (old_templates: ${useOldTemplates})`,
      vod_id: actualVodId,
      source_id: actualSourceId,
      chunks_found: chunks.length,
      chunk_uuids: chunkUuids,
      github_run_url: githubRunUrl || undefined,
    };

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      status: 200,
    });
  } catch (error: any) {
    console.error("Process VOD error:", error);

    const response: ProcessVodResponse = {
      success: false,
      message: "Error processing VOD",
      error: error.message || "Unknown error occurred",
    };

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      status: 500,
    });
  }
}

/**
 * Main entry point - routes to EventSub handler or internal API based on headers
 */
Deno.serve(async (req) => {
  // Check if this is an EventSub webhook (by headers)
  const messageType = req.headers.get("Twitch-Eventsub-Message-Type");

  if (messageType) {
    return handleEventSubWebhook(req, messageType);
  }

  // Otherwise, handle as internal API request
  return handleInternalRequest(req);
});

/* To invoke locally:

  # Process by VOD ID (internal)
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/process-vod' \
    --header "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
    --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"vod_id": 552}'

  # Process by source ID (Twitch VOD ID)
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/process-vod' \
    --header "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
    --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"source_id": "2567780387"}'

  # Dry run to see what would be processed
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/process-vod' \
    --header "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
    --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"vod_id": 552, "dry_run": true}'

  # Test EventSub webhook with Twitch CLI:
  twitch event trigger stream.offline \
    -F http://localhost:54321/functions/v1/process-vod \
    -s $TWITCH_EVENTSUB_SECRET

  Note: The ENV variable in .env/.env.dev determines which GitHub environment
  (dev or production) the workflow will use.

*/
