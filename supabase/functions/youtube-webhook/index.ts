import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { supabase } from "../_shared/supabase.ts";
import {
  readBody,
  topic,
  validSignature,
  verification,
  videoIds,
} from "../_shared/youtube-websub.ts";

// This public callback has its own capability + raw-body HMAC authentication.
Deno.serve(async (req) => {
  if (!["GET", "POST"].includes(req.method)) {
    return new Response(null, { status: 405 });
  }
  const url = new URL(req.url);
  const accountId = url.searchParams.get("account") || "";
  const token = url.searchParams.get("token") || "";
  if (!/^[a-f0-9-]{36}$/.test(accountId) || !/^[a-f0-9]{64}$/.test(token)) {
    return new Response(null, { status: 404 });
  }
  try {
    const { data: subscription, error: subscriptionError } = await supabase
      .from("youtube_websub_subscriptions")
      .select("*").eq("account_id", accountId).eq("callback_token", token)
      .maybeSingle();
    if (subscriptionError) throw new Error("Subscription lookup failed");
    if (!subscription) return new Response(null, { status: 404 });
    const { data: account, error: accountError } = await supabase.from(
      "platform_accounts",
    )
      .select("source_id").eq("id", accountId).eq("source", "youtube").eq(
        "processing_enabled",
        true,
      ).maybeSingle();
    if (accountError) throw new Error("Account lookup failed");
    if (!account) return new Response(null, { status: 404 });
    if (req.method === "GET") {
      if (
        url.searchParams.get("hub.mode") === "denied" &&
        url.searchParams.get("hub.topic") === topic(account.source_id)
      ) {
        const { error } = await supabase.from("youtube_websub_subscriptions")
          .update({
            last_error: "Hub denied subscription; polling remains active",
            requested_at: new Date().toISOString(),
            lease_expires_at: new Date().toISOString(),
          }).eq("account_id", accountId);
        if (error) throw new Error("Denial persistence failed");
        return new Response(null, { status: 204 });
      }
      const verified = verification(url, subscription, account.source_id);
      if (!verified) return new Response(null, { status: 404 });
      const { data: confirmed, error } = await supabase.from(
        "youtube_websub_subscriptions",
      )
        .update({
          confirmed_at: new Date().toISOString(),
          lease_expires_at: verified.expiresAt,
          last_error: null,
          requested_at: null,
        }).eq("account_id", accountId).eq(
          "requested_at",
          subscription.requested_at,
        ).select("account_id");
      if (error || confirmed?.length !== 1) {
        throw new Error("Verification persistence failed");
      }
      return new Response(verified.challenge, {
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
          "X-Content-Type-Options": "nosniff",
          "Cache-Control": "no-store",
        },
      });
    }
    const leaseExpiresAt = Date.parse(subscription.lease_expires_at || "");
    if (
      !subscription.confirmed_at ||
      !Number.isFinite(leaseExpiresAt) || leaseExpiresAt <= Date.now()
    ) {
      return new Response(null, { status: 403 });
    }
    let body: Uint8Array;
    try {
      body = await readBody(req);
    } catch {
      return new Response(null, { status: 413 });
    }
    if (
      !await validSignature(
        body,
        req.headers.get("X-Hub-Signature"),
        subscription.secret,
      )
    ) {
      return new Response(null, { status: 403 });
    }
    let ids: string[];
    try {
      ids = videoIds(
        new TextDecoder("utf-8", { fatal: true }).decode(body),
        account.source_id,
      );
    } catch {
      return new Response(null, { status: 400 });
    }
    const digest = Array.from(
      new Uint8Array(
        await crypto.subtle.digest("SHA-256", body as Uint8Array<ArrayBuffer>),
      ),
    )
      .map((value) => value.toString(16).padStart(2, "0")).join("");
    const { error } = await supabase.rpc("receive_youtube_notification", {
      p_account_id: accountId,
      p_digest: digest,
      p_video_ids: ids,
    });
    if (error) throw new Error("Notification persistence failed");
    return new Response(null, { status: 204 });
  } catch {
    // Do not log the callback URL, HMAC secret, signature, or raw payload.
    console.error("YouTube notification persistence failed");
    return new Response(null, { status: 503 });
  }
});
