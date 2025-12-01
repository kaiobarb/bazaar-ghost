import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "jsr:@supabase/supabase-js@2"
import nacl from "https://cdn.skypack.dev/tweetnacl@v1.0.3?dts"

enum DiscordCommandType {
  Ping = 1,
  ApplicationCommand = 2,
}

function getSupabaseClient() {
  return createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  )
}

Deno.serve(async (req) => {
  // Only allow POST
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 })
  }

  // Verify Discord signature
  const signature = req.headers.get("X-Signature-Ed25519")
  const timestamp = req.headers.get("X-Signature-Timestamp")

  if (!signature || !timestamp) {
    return new Response("Missing signature headers", { status: 401 })
  }

  const body = await req.text()
  const isValid = verifySignature(signature, timestamp, body)

  if (!isValid) {
    return new Response("Invalid signature", { status: 401 })
  }

  const { type, data, member } = JSON.parse(body)

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

    const supabase = getSupabaseClient()

    // /notify <username> - Toggle notifications for a username
    if (name === "notify") {
      const username = options?.find((o: { name: string; value: string }) => o.name === "username")?.value

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
        .ilike("username", username)
        .maybeSingle()

      if (existing) {
        // Toggle the existing subscription
        const newEnabled = !existing.enabled
        const { error } = await supabase
          .from("notification_subscriptions")
          .update({ enabled: newEnabled })
          .eq("discord_user_id", discordUserId)
          .ilike("username", username)

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

function verifySignature(signature: string, timestamp: string, body: string): boolean {
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
