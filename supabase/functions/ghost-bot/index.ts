import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { supabase, verifySecretKey } from "../_shared/supabase.ts";
import nacl from "https://cdn.skypack.dev/tweetnacl@v1.0.3?dts";

enum DiscordCommandType {
  Ping = 1,
  ApplicationCommand = 2,
}

Deno.serve(async (req) => {
  // Only allow POST
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  // Clone request to read body multiple times
  const body = await req.text();
  const json = JSON.parse(body);

  // Handle internal trigger calls (action: "notify") - verified via apikey
  if (json.action === "notify") {
    if (!verifySecretKey(req)) {
      return new Response("Unauthorized", { status: 401 });
    }

    const {
      username,
      frame_time_seconds,
      vod_source_id,
      vod_published_at,
      streamer_name,
    } = json;

    // Find matching subscriptions (case-sensitive exact match)
    const { data: subscriptions } = await supabase
      .from("notification_subscriptions")
      .select("discord_user_id, notify_type, guild_id")
      .eq("username", username)
      .eq("enabled", true);

    if (!subscriptions || subscriptions.length === 0) {
      return Response.json({ notified: 0 });
    }

    // Build timestamped VOD URL (format: ?t=1h2m3s)
    const hours = Math.floor(frame_time_seconds / 3600);
    const minutes = Math.floor((frame_time_seconds % 3600) / 60);
    const seconds = frame_time_seconds % 60;
    const timeParam = `${hours}h${minutes}m${seconds}s`;
    const vodUrl =
      `https://www.twitch.tv/videos/${vod_source_id}?t=${timeParam}`;

    // Calculate matchup time (vod publish time + frame time) as Unix timestamp
    const publishDate = new Date(vod_published_at);
    const matchupTimestamp = Math.floor(
      (publishDate.getTime() + frame_time_seconds * 1000) / 1000,
    );

    const baseMessage =
      `👻🚨 New matchup found!\n**${streamer_name}** vs **${username}**\n` +
      `<t:${matchupTimestamp}:f>\n` +
      `${vodUrl}`;

    let notifiedCount = 0;

    // Group subscriptions by guild_id for server notifications
    const serverSubs = new Map<string, string[]>();

    for (const sub of subscriptions) {
      const notifyType = sub.notify_type || "both";

      // Send DM if notify_type is "dm" or "both"
      if (notifyType === "dm" || notifyType === "both") {
        await sendDiscordDM(sub.discord_user_id, baseMessage);
        notifiedCount++;
      }

      // Collect server notifications to send
      if ((notifyType === "server" || notifyType === "both") && sub.guild_id) {
        const existing = serverSubs.get(sub.guild_id) || [];
        existing.push(sub.discord_user_id);
        serverSubs.set(sub.guild_id, existing);
      }
    }

    // Send server channel notifications
    for (const [guildId, userIds] of serverSubs) {
      // Get the channel for this server
      const { data: serverChannel } = await supabase
        .from("server_channels")
        .select("channel_id")
        .eq("guild_id", guildId)
        .maybeSingle();

      if (serverChannel?.channel_id) {
        // Include @mentions for all users in this server
        const mentions = userIds.map((id) => `<@${id}>`).join(" ");
        const serverMessage = `${baseMessage}\n${mentions}`;
        await sendDiscordChannelMessage(serverChannel.channel_id, serverMessage);
        notifiedCount += userIds.length;
      }
    }

    return Response.json({ notified: notifiedCount });
  }

  // Discord webhook calls - verify signature
  const signature = req.headers.get("X-Signature-Ed25519");
  const timestamp = req.headers.get("X-Signature-Timestamp");

  if (!signature || !timestamp) {
    return new Response("Missing signature headers", { status: 401 });
  }

  const isValid = verifyDiscordSignature(signature, timestamp, body);

  if (!isValid) {
    return new Response("Invalid signature", { status: 401 });
  }

  const { type, data, member, channel_id, guild_id } = json;

  // Handle Discord ping (verification)
  if (type === DiscordCommandType.Ping) {
    return Response.json({ type: 1 });
  }

  // Handle slash commands
  if (type === DiscordCommandType.ApplicationCommand) {
    const { name, options } = data;
    const discordUserId = member?.user?.id;

    if (!discordUserId) {
      return Response.json({
        type: 4,
        data: { content: "Could not identify user", flags: 64 },
      });
    }

    // /help - Show available commands
    if (name === "help") {
      const helpText = `**Bazaar Ghost Bot**
Get notified when your username appears on a streamer's VOD.

**Commands:**
\`/search <username>\` - Search for a username in detected matchups
\`/notify <username>\` - Subscribe to notifications (default: DM + server)
\`/notify <username> where:<option>\` - Choose where to receive notifications
\`/list\` - Show your active subscriptions
\`/setchannel [channel]\` - Set notification channel for this server (requires Manage Channels)

**How it works:**
1. Use \`/notify YourBazaarName\` to subscribe
2. When your name is detected in a streamer's VOD, you'll get a notification with a timestamped link
3. Use \`/notify YourBazaarName\` again to unsubscribe`;

      return Response.json({
        type: 4,
        data: { content: helpText, flags: 64 },
      });
    }

    // /setchannel - Admin-only command to set notification channel for server
    if (name === "setchannel") {
      // Get channel from options or use current channel
      const channelOption = options?.find(
        (o: { name: string; value: string }) => o.name === "channel"
      )?.value;
      const targetChannelId = channelOption || channel_id;

      if (!guild_id) {
        return Response.json({
          type: 4,
          data: {
            content: "This command can only be used in a server",
            flags: 64,
          },
        });
      }

      // Upsert server channel
      const { error } = await supabase.from("server_channels").upsert(
        { guild_id, channel_id: targetChannelId },
        { onConflict: "guild_id" }
      );

      if (error) {
        console.error("DB error:", error);
        return Response.json({
          type: 4,
          data: { content: `Error: ${error.message}`, flags: 64 },
        });
      }

      return Response.json({
        type: 4,
        data: {
          content: `Notifications will be posted to <#${targetChannelId}>`,
          flags: 64,
        },
      });
    }

    // /notify <username> [where] - Toggle notifications for a username
    if (name === "notify") {
      const username = options?.find((o: { name: string; value: string }) =>
        o.name === "bazaar_username"
      )?.value;

      const whereOption =
        options?.find((o: { name: string; value: string }) => o.name === "where")
          ?.value || "both";

      if (!username) {
        return Response.json({
          type: 4,
          data: { content: "Please provide a username", flags: 64 },
        });
      }

      // If server or both, require guild_id
      if ((whereOption === "server" || whereOption === "both") && !guild_id) {
        return Response.json({
          type: 4,
          data: {
            content:
              "Server notifications require using this command in a server",
            flags: 64,
          },
        });
      }

      // If server or both, check server_channels exists
      if (whereOption === "server" || whereOption === "both") {
        const { data: serverChannel } = await supabase
          .from("server_channels")
          .select("channel_id")
          .eq("guild_id", guild_id)
          .maybeSingle();

        if (!serverChannel) {
          return Response.json({
            type: 4,
            data: {
              content:
                "No notification channel set for this server. Ask an admin to use `/setchannel` first.",
              flags: 64,
            },
          });
        }
      }

      // Check if subscription exists
      const { data: existing } = await supabase
        .from("notification_subscriptions")
        .select("enabled")
        .eq("discord_user_id", discordUserId)
        .eq("username", username)
        .maybeSingle();

      if (existing) {
        // Toggle the existing subscription
        const newEnabled = !existing.enabled;
        const updateData: {
          enabled: boolean;
          notify_type?: string;
          guild_id?: string | null;
        } = { enabled: newEnabled };

        // If re-enabling, update notify_type and guild_id
        if (newEnabled) {
          updateData.notify_type = whereOption;
          updateData.guild_id =
            whereOption === "server" || whereOption === "both" ? guild_id : null;
        }

        const { error } = await supabase
          .from("notification_subscriptions")
          .update(updateData)
          .eq("discord_user_id", discordUserId)
          .eq("username", username);

        if (error) {
          console.error("DB error:", error);
          return Response.json({
            type: 4,
            data: { content: `Error: ${error.message}`, flags: 64 },
          });
        }

        const action = newEnabled ? "Subscribed to" : "Unsubscribed from";
        const whereText = newEnabled ? ` (${formatWhereOption(whereOption)})` : "";
        return Response.json({
          type: 4,
          data: {
            content: `${action} notifications on username **${username}**${whereText}`,
            flags: 64,
          },
        });
      } else {
        // Create new subscription
        const { error } = await supabase
          .from("notification_subscriptions")
          .insert({
            discord_user_id: discordUserId,
            username,
            enabled: true,
            notify_type: whereOption,
            guild_id:
              whereOption === "server" || whereOption === "both" ? guild_id : null,
          });

        if (error) {
          console.error("DB error:", error);
          return Response.json({
            type: 4,
            data: { content: `Error: ${error.message}`, flags: 64 },
          });
        }

        return Response.json({
          type: 4,
          data: {
            content: `Subscribed to notifications on username **${username}** (${formatWhereOption(whereOption)})`,
            flags: 64,
          },
        });
      }
    }

    // /list - Show all enabled subscriptions for the user
    if (name === "list") {
      const { data: subscriptions, error } = await supabase
        .from("notification_subscriptions")
        .select("username, enabled, created_at")
        .eq("discord_user_id", discordUserId)
        .eq("enabled", true)
        .order("created_at", { ascending: true });

      if (error) {
        console.error("DB error:", error);
        return Response.json({
          type: 4,
          data: { content: `Error: ${error.message}`, flags: 64 },
        });
      }

      if (!subscriptions || subscriptions.length === 0) {
        return Response.json({
          type: 4,
          data: {
            content:
              "You have no active subscriptions. Use `/notify <username>` to subscribe.",
            flags: 64,
          },
        });
      }

      const usernameList = subscriptions.map((s) => `• **${s.username}**`).join(
        "\n",
      );
      return Response.json({
        type: 4,
        data: { content: `Your active subscriptions:\n${usernameList}`, flags: 64 },
      });
    }

    // /search <username> - Search for a username in detected matchups
    if (name === "search") {
      const searchUsername = options?.find(
        (o: { name: string; value: string }) => o.name === "username"
      )?.value;

      if (!searchUsername) {
        return Response.json({
          type: 4,
          data: { content: "Please provide a username to search", flags: 64 },
        });
      }

      // Call fuzzy_search_detections with similarity_threshold=1.0 for exact matches
      const { data: results, error } = await supabase.rpc(
        "fuzzy_search_detections",
        {
          search_query: searchUsername,
          similarity_threshold: 1.0,
          result_limit: 10,
        }
      );

      if (error) {
        console.error("DB error:", error);
        return Response.json({
          type: 4,
          data: { content: `Error: ${error.message}`, flags: 64 },
        });
      }

      if (!results || results.length === 0) {
        return Response.json({
          type: 4,
          data: {
            content: `No results found for **${searchUsername}**`,
            flags: 64,
          },
        });
      }

      // Format results
      const resultLines = results.map((r: {
        streamer_display_name: string;
        actual_timestamp: string;
        vod_source_id: string;
        frame_time_seconds: number;
      }) => {
        const timestamp = Math.floor(new Date(r.actual_timestamp).getTime() / 1000);
        const hours = Math.floor(r.frame_time_seconds / 3600);
        const minutes = Math.floor((r.frame_time_seconds % 3600) / 60);
        const seconds = r.frame_time_seconds % 60;
        const timeParam = `${hours}h${minutes}m${seconds}s`;
        const vodUrl = `https://www.twitch.tv/videos/${r.vod_source_id}?t=${timeParam}`;
        return `• **${r.streamer_display_name}** - <t:${timestamp}:f> - [Watch](${vodUrl})`;
      });

      return Response.json({
        type: 4,
        data: {
          content: `**Results for "${searchUsername}":**\n${resultLines.join("\n")}`,
          flags: 64,
        },
      });
    }
  }

  return Response.json({ error: "Unknown command" }, { status: 400 });
});

function verifyDiscordSignature(
  signature: string,
  timestamp: string,
  body: string,
): boolean {
  const publicKey = Deno.env.get("DISCORD_PUBLIC_KEY")!;
  return nacl.sign.detached.verify(
    new TextEncoder().encode(timestamp + body),
    hexToUint8Array(signature),
    hexToUint8Array(publicKey),
  );
}

function hexToUint8Array(hex: string): Uint8Array {
  return new Uint8Array(hex.match(/.{1,2}/g)!.map((val) => parseInt(val, 16)));
}

function formatWhereOption(where: string): string {
  switch (where) {
    case "dm":
      return "DM only";
    case "server":
      return "server only";
    case "both":
      return "DM + server";
    default:
      return where;
  }
}

async function sendDiscordDM(userId: string, content: string) {
  const botToken = Deno.env.get("DISCORD_BOT_TOKEN")!;

  // Create DM channel
  const channelRes = await fetch(
    "https://discord.com/api/v10/users/@me/channels",
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bot ${botToken}`,
      },
      body: JSON.stringify({ recipient_id: userId }),
    },
  );
  const channel = await channelRes.json();

  if (!channel.id) {
    console.error("Failed to create DM channel:", channel);
    return;
  }

  // Send message
  const msgRes = await fetch(
    `https://discord.com/api/v10/channels/${channel.id}/messages`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bot ${botToken}`,
      },
      body: JSON.stringify({ content }),
    },
  );

  if (!msgRes.ok) {
    console.error("Failed to send DM:", await msgRes.text());
  }
}

async function sendDiscordChannelMessage(channelId: string, content: string) {
  const botToken = Deno.env.get("DISCORD_BOT_TOKEN")!;

  const msgRes = await fetch(
    `https://discord.com/api/v10/channels/${channelId}/messages`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bot ${botToken}`,
      },
      body: JSON.stringify({ content }),
    },
  );

  if (!msgRes.ok) {
    console.error("Failed to send channel message:", await msgRes.text());
  }
}
