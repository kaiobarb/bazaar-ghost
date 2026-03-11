import { supabase } from "./supabase.ts";
import { createEventSubSubscription } from "./twitch.ts";
import { log, recordCounter } from "./telemetry.ts";

/**
 * Ensure EventSub subscription exists for a processing-enabled streamer.
 * Creates subscription if not already present, and updates the database
 * with the subscription ID.
 */
export async function ensureEventSubSubscription(
  streamerId: number,
  streamerLogin: string,
): Promise<void> {
  log("info", "Ensuring EventSub subscription exists", {
    streamer_id: streamerId,
    login: streamerLogin,
  });

  const result = await createEventSubSubscription(streamerId.toString());

  if (result.success) {
    // Update database with subscription ID
    const { error } = await supabase
      .from("streamers")
      .update({ eventsub_subscription_id: result.subscription_id })
      .eq("id", streamerId);

    if (error) {
      log("error", "Failed to update streamer with subscription ID", {
        streamer_id: streamerId,
        error: error.message,
      });
    } else {
      recordCounter("eventsub.subscription.created", 1, {
        streamer: streamerLogin,
        already_existed: result.already_exists.toString(),
      });
      log("info", "EventSub subscription ensured", {
        streamer_id: streamerId,
        subscription_id: result.subscription_id,
        already_existed: result.already_exists,
      });
    }
  } else {
    recordCounter("eventsub.subscription.failed", 1, {
      streamer: streamerLogin,
    });
    log("error", "Failed to create EventSub subscription", {
      streamer_id: streamerId,
      error: result.error,
    });
  }
}
