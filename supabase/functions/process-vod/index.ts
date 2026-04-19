// Process VOD - Find and trigger processing for all pending chunks of a VOD
// Also handles Twitch EventSub stream.offline webhooks
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

import {
  OLD_TEMPLATES_CUTOFF,
  triggerGithubWorkflow,
} from "../_shared/github.ts";
import {
  fetchAndUpsertVods,
  fetchVodProcessingConfig,
  getPendingChunksForVod,
  supabase,
  verifySecretKey,
} from "../_shared/supabase.ts";
import { verifyEventSubSignature } from "../_shared/twitch.ts";
import { log, recordCounter } from "../_shared/telemetry.ts";

const TWITCH_EVENTSUB_SECRET = Deno.env.get("TWITCH_EVENTSUB_SECRET")!;

interface ProcessVodRequest {
  vod_id?: number | string;
  source_id?: string;
  dry_run?: boolean;
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

// ---------------------------------------------------------------------------
// EventSub handler
// ---------------------------------------------------------------------------

async function handleEventSubWebhook(
  req: Request,
  messageType: string,
): Promise<Response> {
  const body = await req.text();
  const messageId = req.headers.get("Twitch-Eventsub-Message-Id");
  const timestamp = req.headers.get("Twitch-Eventsub-Message-Timestamp");
  const signature = req.headers.get("Twitch-Eventsub-Message-Signature");

  recordCounter("eventsub.webhook.received", 1, { message_type: messageType });

  if (!messageId || !timestamp || !signature) {
    log("warn", "Missing EventSub headers", { messageId, timestamp, signature });
    return new Response("Missing required headers", { status: 400 });
  }

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

  if (messageType === "webhook_callback_verification") {
    log("info", "EventSub challenge verification", {
      subscription_type: payload.subscription.type,
    });
    return new Response(payload.challenge, {
      status: 200,
      headers: { "Content-Type": "text/plain" },
    });
  }

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

  // Look up streamer (by ID first, login as fallback for local testing)
  const { data: streamerById } = await supabase
    .from("streamers")
    .select("id, login, display_name, processing_enabled")
    .eq("id", parseInt(broadcaster_user_id))
    .single();

  const streamer = streamerById ?? await (async () => {
    const { data } = await supabase
      .from("streamers")
      .select("id, login, display_name, processing_enabled")
      .eq("login", broadcaster_user_login)
      .single();
    return data;
  })();

  if (!streamer) {
    recordCounter("eventsub.stream_offline.skipped", 1, { reason: "not_found" });
    log("info", "Streamer not found in database", {
      user_id: broadcaster_user_id,
      login: broadcaster_user_login,
    });
    return;
  }

  if (!streamer.processing_enabled) {
    recordCounter("eventsub.stream_offline.skipped", 1, { reason: "disabled" });
    log("info", "Processing disabled for streamer", {
      streamer_id: streamer.id,
      login: streamer.login,
    });
    return;
  }

  const { vodsUpserted, bazaarSegments, upsertedVodIds } =
    await fetchAndUpsertVods(streamer.id, streamer.login, 1);

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

  try {
    const chunks = await getPendingChunksForVod(undefined, vodSourceId);
    if (chunks.length === 0) {
      log("info", "No pending chunks for new VOD", { vod_source_id: vodSourceId });
      return;
    }

    const chunkUuids = chunks.map((c) => c.chunk_id);
    const { useOldTemplates, sfdeProfileJson } = await fetchVodProcessingConfig(
      chunks[0].vod_id,
      OLD_TEMPLATES_CUTOFF,
    );
    const environment = Deno.env.get("ENV") || "production";

    await supabase.from("chunks").update({ status: "queued" }).in(
      "id",
      chunkUuids,
    );

    const githubRunUrl = await triggerGithubWorkflow(
      vodSourceId,
      chunkUuids,
      useOldTemplates,
      sfdeProfileJson,
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
  } catch (error: unknown) {
    log("error", "Failed to trigger processing for stream.offline VOD", {
      vod_source_id: vodSourceId,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

// ---------------------------------------------------------------------------
// Internal API handler
// ---------------------------------------------------------------------------

async function handleInternalRequest(req: Request): Promise<Response> {
  try {
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

    if (!verifySecretKey(req)) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        headers: { "Content-Type": "application/json" },
        status: 401,
      });
    }

    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 });
    }

    const { vod_id, source_id, dry_run = false }: ProcessVodRequest =
      await req.json().catch(() => ({}));

    console.log(
      `Process VOD request - vod_id: ${vod_id}, source_id: ${source_id}, dry_run: ${dry_run}`,
    );

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

    const chunks = await getPendingChunksForVod(vod_id, source_id);

    if (chunks.length === 0) {
      const response: ProcessVodResponse = {
        success: true,
        message: "No pending chunks found for this VOD",
        vod_id: vod_id ? Number(vod_id) : undefined,
        source_id,
        chunks_found: 0,
      };
      return new Response(JSON.stringify(response), {
        headers: { "Content-Type": "application/json" },
        status: 200,
      });
    }

    const chunkUuids = chunks.map((c) => c.chunk_id);
    const actualVodId = chunks[0].vod_id;
    const actualSourceId = chunks[0].source_id;

    console.log(
      `Found ${chunks.length} pending chunks for VOD ${actualVodId} (${actualSourceId})`,
    );

    const { useOldTemplates, sfdeProfileJson } = await fetchVodProcessingConfig(
      actualVodId,
      OLD_TEMPLATES_CUTOFF,
    );
    const environment = Deno.env.get("ENV") || "production";

    console.log(
      `use old templates: ${useOldTemplates}, environment: ${environment}`,
    );

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

    console.log(`Updating ${chunks.length} chunks to 'queued' status`);
    const { error: updateError } = await supabase
      .from("chunks")
      .update({ status: "queued" })
      .in("id", chunkUuids);

    if (updateError) {
      throw new Error(
        `Failed to update chunks to queued status: ${updateError.message}`,
      );
    }

    const githubRunUrl = await triggerGithubWorkflow(
      actualSourceId,
      chunkUuids,
      useOldTemplates,
      sfdeProfileJson,
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
      github_run_url: githubRunUrl,
    };

    return new Response(JSON.stringify(response), {
      headers: {
        "Content-Type": "application/json",
        "Access-Control-Allow-Origin": "*",
      },
      status: 200,
    });
  } catch (error: unknown) {
    console.error("Process VOD error:", error);
    const response: ProcessVodResponse = {
      success: false,
      message: "Error processing VOD",
      error: error instanceof Error ? error.message : "Unknown error occurred",
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

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

Deno.serve(async (req) => {
  const messageType = req.headers.get("Twitch-Eventsub-Message-Type");
  if (messageType) return handleEventSubWebhook(req, messageType);
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

  # Dry run
  curl -i --location --request POST 'http://127.0.0.1:54321/functions/v1/process-vod' \
    --header "Authorization: Bearer $SUPABASE_PUBLISHABLE_KEY" \
    --header "apikey: $SUPABASE_PUBLISHABLE_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"vod_id": 552, "dry_run": true}'

  # Test EventSub webhook with Twitch CLI:
  twitch event trigger stream.offline \
    -F http://localhost:54321/functions/v1/process-vod \
    -s $TWITCH_EVENTSUB_SECRET

*/
