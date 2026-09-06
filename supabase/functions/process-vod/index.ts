import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  fetchAndUpsertVods,
  supabase,
  syncStreamerIdentity,
  verifySecretKey,
} from "../_shared/supabase.ts";
import { dispatchProcessing, planProcessing } from "../_shared/processing.ts";
import { verifyEventSubSignature } from "../_shared/twitch.ts";
import { corsHeaders } from "../_shared/cors.ts";

interface OfflineEvent {
  broadcaster_user_id: string;
  broadcaster_user_login: string;
  broadcaster_user_name: string;
}

async function processOffline(event: OfflineEvent): Promise<void> {
  const { data: streamer, error } = await supabase.from("streamers")
    .select("id, login, display_name, processing_enabled")
    .eq("id", event.broadcaster_user_id).maybeSingle();
  if (error) throw new Error(error.message);
  if (!streamer) return;
  await syncStreamerIdentity({
    id: streamer.id,
    login: event.broadcaster_user_login,
    display_name: event.broadcaster_user_name,
  }, streamer);
  if (!streamer.processing_enabled) return;
  const { upsertedVodIds } = await fetchAndUpsertVods(
    streamer.id,
    event.broadcaster_user_login,
    1,
  );
  if (!upsertedVodIds.length) return;
  const plan = await planProcessing(undefined, upsertedVodIds[0]);
  if (plan) await dispatchProcessing(plan);
}

async function handleEventSub(
  req: Request,
  messageType: string,
): Promise<Response> {
  const body = await req.text();
  const messageId = req.headers.get("Twitch-Eventsub-Message-Id");
  const timestamp = req.headers.get("Twitch-Eventsub-Message-Timestamp");
  const signature = req.headers.get("Twitch-Eventsub-Message-Signature");
  const secret = Deno.env.get("TWITCH_EVENTSUB_SECRET");
  if (!messageId || !timestamp || !signature) {
    return new Response("Missing EventSub headers", { status: 400 });
  }
  if (!secret) {
    return new Response("EventSub is not configured", { status: 500 });
  }
  if (
    !await verifyEventSubSignature(
      messageId,
      timestamp,
      body,
      signature,
      secret,
    )
  ) {
    return new Response("Invalid EventSub signature or timestamp", {
      status: 403,
    });
  }
  const payload = JSON.parse(body);
  if (messageType === "webhook_callback_verification") {
    if (typeof payload.challenge !== "string") {
      return new Response("Missing challenge", { status: 400 });
    }
    return new Response(payload.challenge, {
      headers: { "Content-Type": "text/plain" },
    });
  }
  if (messageType === "revocation") {
    const { error } = await supabase.from("streamers")
      .update({ eventsub_subscription_id: null }).eq(
        "eventsub_subscription_id",
        payload.subscription.id,
      );
    if (error) throw new Error(error.message);
  } else if (
    messageType === "notification" &&
    payload.subscription?.type === "stream.offline" && payload.event
  ) {
    await processOffline(payload.event);
  }
  return new Response(null, { status: 204 });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  try {
    const messageType = req.headers.get("Twitch-Eventsub-Message-Type");
    if (messageType) return await handleEventSub(req, messageType);
    if (!verifySecretKey(req)) {
      return new Response("Unauthorized", { status: 401 });
    }
    const { vod_id, source_id, dry_run = false } = await req.json();
    if (
      (vod_id == null) === (source_id == null) ||
      (vod_id != null &&
        (!Number.isSafeInteger(Number(vod_id)) || Number(vod_id) <= 0)) ||
      (source_id != null && !/^\d+$/.test(String(source_id))) ||
      typeof dry_run !== "boolean"
    ) {
      return Response.json({
        error:
          "Provide one positive vod_id or numeric source_id, and a boolean dry_run",
      }, { status: 400, headers: corsHeaders });
    }
    const plan = await planProcessing(
      vod_id == null ? undefined : Number(vod_id),
      source_id == null ? undefined : String(source_id),
    );
    if (!plan) {
      return Response.json({
        success: true,
        chunks_found: 0,
        message: "No pending chunks found",
      }, { headers: corsHeaders });
    }
    const ids = dry_run
      ? plan.chunks.map((chunk) => chunk.chunk_id)
      : await dispatchProcessing(plan);
    return Response.json({
      success: true,
      vod_id: plan.vod_id,
      source_id: plan.source_id,
      chunks_found: ids.length,
      chunk_uuids: ids,
      message: dry_run ? "Dry run: processing plan" : "Processing queued",
      old_templates: plan.old_templates,
      github_run_url: dry_run || !ids.length
        ? undefined
        : "https://github.com/kaiobarb/bazaar-ghost/actions/workflows/process-vod.yml",
    }, { headers: corsHeaders });
  } catch (error: any) {
    console.error("Process VOD failed:", error);
    return Response.json({ success: false, error: error.message }, {
      status: error instanceof SyntaxError ? 400 : 500,
      headers: corsHeaders,
    });
  }
});
