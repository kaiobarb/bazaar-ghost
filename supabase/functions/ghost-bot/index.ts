import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { supabase, verifySecretKey } from "../_shared/supabase.ts"
import nacl from "https://cdn.skypack.dev/tweetnacl@v1.0.3?dts"

enum DiscordCommandType {
  Ping = 1,
  ApplicationCommand = 2,
}

Deno.serve(async (req) => {
  // Only allow POST
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 })
  }

  // Clone request to read body multiple times
  const body = await req.text()
  const json = JSON.parse(body)

  // Handle internal trigger calls (action: "notify") - verified via apikey
  if (json.action === "notify") {
    if (!verifySecretKey(req)) {
      return new Response("Unauthorized", { status: 401 })
    }

    const { username, frame_time_seconds, vod_source_id, vod_published_at, streamer_name } = json

    // Find matching subscriptions (case-sensitive exact match)
    const { data: subscriptions } = await supabase
      .from("notification_subscriptions")
      .select("discord_user_id")
      .eq("username", username)
      .eq("enabled", true)

    if (!subscriptions || subscriptions.length === 0) {
      return Response.json({ notified: 0 })
    }

    // Build timestamped VOD URL (format: ?t=1h2m3s)
    const hours = Math.floor(frame_time_seconds / 3600)
    const minutes = Math.floor((frame_time_seconds % 3600) / 60)
    const seconds = frame_time_seconds % 60
    const timeParam = `${hours}h${minutes}m${seconds}s`
    const vodUrl = `https://www.twitch.tv/videos/${vod_source_id}?t=${timeParam}`

    // Calculate matchup time (vod publish time + frame time)
    const publishDate = new Date(vod_published_at)
    const matchupTime = new Date(publishDate.getTime() + frame_time_seconds * 1000)
    const matchupTimeStr = matchupTime.toLocaleString("en-US", {
      weekday: "short",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short"
    })

    const message = `**${username}** was spotted on **${streamer_name}**'s stream!\n` +
      `${matchupTimeStr}\n` +
      `${vodUrl}`

    // Send Discord DM to each subscriber
    for (const sub of subscriptions) {
      await sendDiscordDM(sub.discord_user_id, message)
    }

    return Response.json({ notified: subscriptions.length })
  }

  // Discord webhook calls - verify signature
  const signature = req.headers.get("X-Signature-Ed25519")
  const timestamp = req.headers.get("X-Signature-Timestamp")

  if (!signature || !timestamp) {
    return new Response("Missing signature headers", { status: 401 })
  }

  const isValid = verifyDiscordSignature(signature, timestamp, body)

  if (!isValid) {
    return new Response("Invalid signature", { status: 401 })
  }

  const { type, data, member } = json

  // Handle Discord ping (verification)
  if (type === DiscordCommandType.Ping) {
    return Response.json({ type: 1 })
  }

  // Handle slash commands
  if (type === DiscordCommandType.ApplicationCommand) {
    const { name, options } = data
    const discordUserId = member?.user?.id

    if (!discordUserId) {
      return Response.json({
        type: 4,
        data: { content: "Could not identify user", flags: 64 }
      })
    }

    // /notify <username> - Toggle notifications for a username
    if (name === "notify") {
      const username = options?.find((o: { name: string; value: string }) => o.name === "bazaar_username")?.value

      if (!username) {
        return Response.json({
          type: 4,
          data: { content: "Please provide a username", flags: 64 }
        })
      }

      // Check if subscription exists
      const { data: existing } = await supabase
        .from("notification_subscriptions")
        .select("enabled")
        .eq("discord_user_id", discordUserId)
        .eq("username", username)
        .maybeSingle()

      if (existing) {
        // Toggle the existing subscription
        const newEnabled = !existing.enabled
        const { error } = await supabase
          .from("notification_subscriptions")
          .update({ enabled: newEnabled })
          .eq("discord_user_id", discordUserId)
          .eq("username", username)

        if (error) {
          console.error("DB error:", error)
          return Response.json({
            type: 4,
            data: { content: `Error: ${error.message}`, flags: 64 }
          })
        }

        const action = newEnabled ? "Subscribed to" : "Unsubscribed from"
        return Response.json({
          type: 4,
          data: { content: `${action} notifications on username **${username}**` }
        })
      } else {
        // Create new subscription
        const { error } = await supabase
          .from("notification_subscriptions")
          .insert({ discord_user_id: discordUserId, username, enabled: true })

        if (error) {
          console.error("DB error:", error)
          return Response.json({
            type: 4,
            data: { content: `Error: ${error.message}`, flags: 64 }
          })
        }

        return Response.json({
          type: 4,
          data: { content: `Subscribed to notifications on username **${username}**` }
        })
      }
    }

    // /list - Show all enabled subscriptions for the user
    if (name === "list") {
      const { data: subscriptions, error } = await supabase
        .from("notification_subscriptions")
        .select("username, enabled, created_at")
        .eq("discord_user_id", discordUserId)
        .eq("enabled", true)
        .order("created_at", { ascending: true })

      if (error) {
        console.error("DB error:", error)
        return Response.json({
          type: 4,
          data: { content: `Error: ${error.message}`, flags: 64 }
        })
      }

      if (!subscriptions || subscriptions.length === 0) {
        return Response.json({
          type: 4,
          data: { content: "You have no active subscriptions. Use `/notify <username>` to subscribe." }
        })
      }

      const usernameList = subscriptions.map(s => `• **${s.username}**`).join("\n")
      return Response.json({
        type: 4,
        data: { content: `Your active subscriptions:\n${usernameList}` }
      })
    }
  }

  return Response.json({ error: "Unknown command" }, { status: 400 })
})

function verifyDiscordSignature(signature: string, timestamp: string, body: string): boolean {
  const publicKey = Deno.env.get("DISCORD_PUBLIC_KEY")!
  return nacl.sign.detached.verify(
    new TextEncoder().encode(timestamp + body),
    hexToUint8Array(signature),
    hexToUint8Array(publicKey)
  )
}

function hexToUint8Array(hex: string): Uint8Array {
  return new Uint8Array(hex.match(/.{1,2}/g)!.map((val) => parseInt(val, 16)))
}

async function sendDiscordDM(userId: string, content: string) {
  const botToken = Deno.env.get("DISCORD_BOT_TOKEN")!

  // Create DM channel
  const channelRes = await fetch("https://discord.com/api/v10/users/@me/channels", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bot ${botToken}`,
    },
    body: JSON.stringify({ recipient_id: userId }),
  })
  const channel = await channelRes.json()

  if (!channel.id) {
    console.error("Failed to create DM channel:", channel)
    return
  }

  // Send message
  const msgRes = await fetch(`https://discord.com/api/v10/channels/${channel.id}/messages`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bot ${botToken}`,
    },
    body: JSON.stringify({ content }),
  })

  if (!msgRes.ok) {
    console.error("Failed to send DM:", await msgRes.text())
  }
}
