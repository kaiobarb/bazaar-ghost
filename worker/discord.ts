import {
  external,
  now,
  readText,
  one,
  requireValue,
  rows,
  statement,
} from "./http";
import { search } from "./search";

const reply = (content: string) =>
  Response.json({
    type: 4,
    data: {
      content: content.slice(0, 1950),
      flags: 64,
      allowed_mentions: { parse: [] },
    },
  });
export async function discord(req: Request, env: Env) {
  const raw = await readText(req),
    signature = req.headers.get("X-Signature-Ed25519") || "",
    timestamp = req.headers.get("X-Signature-Timestamp") || "";
  if (
    !/^[a-f\d]{128}$/i.test(signature) ||
    !/^[a-f\d]{64}$/i.test(env.DISCORD_PUBLIC_KEY) ||
    !/^\d+$/.test(timestamp) ||
    Math.abs(Date.now() - Number(timestamp) * 1000) > 300_000
  )
    return new Response("Invalid signature", { status: 401 });
  const bytes = (hex: string) =>
    new Uint8Array(hex.match(/../g)!.map((s) => parseInt(s, 16)));
  const key = await crypto.subtle.importKey(
    "raw",
    bytes(env.DISCORD_PUBLIC_KEY),
    { name: "Ed25519" },
    false,
    ["verify"],
  );
  if (
    !(await crypto.subtle.verify(
      "Ed25519",
      key,
      bytes(signature),
      new TextEncoder().encode(timestamp + raw),
    ))
  )
    return new Response("Invalid signature", { status: 401 });
  const data = JSON.parse(raw);
  if (data.type === 1) return Response.json({ type: 1 });
  if (data.type !== 2) return reply("Unknown command");
  const user = data.member?.user?.id || data.user?.id,
    guild = data.guild_id;
  if (!user) return reply("Could not identify user");
  const name = data.data?.name,
    options = data.data?.options || [];
  const option = (key: string) =>
    options.find((o: any) => o.name === key)?.value;
  if (name === "help")
    return reply(
      "Use /search <username> to find matchups, /notify <bazaar_username> [where] to toggle notifications, /list to show subscriptions, and /setchannel or /clearchannel to configure a server.",
    );
  if (name === "setchannel" || name === "clearchannel") {
    if (!guild) return reply("This command can only be used in a server");
    if (!(BigInt(data.member?.permissions || "0") & (8n | 32n)))
      return reply("Manage Server permission is required");
    if (name === "clearchannel")
      await statement(
        env,
        "DELETE FROM server_channels WHERE guild_id=?",
        guild,
      ).run();
    else
      await statement(
        env,
        "INSERT INTO server_channels(guild_id,channel_id) VALUES(?,?) ON CONFLICT(guild_id) DO UPDATE SET channel_id=excluded.channel_id",
        guild,
        option("channel") || data.channel_id,
      ).run();
    return reply(
      name === "clearchannel"
        ? "Notification channel cleared"
        : `Notifications will be posted to <#${option("channel") || data.channel_id}>`,
    );
  }
  if (name === "notify") {
    const username = option("bazaar_username"),
      where = option("where") || "both";
    if (
      typeof username !== "string" ||
      !username.trim() ||
      username.length > 128
    )
      return reply("Please provide a username of at most 128 characters");
    if (!["dm", "server", "both"].includes(where))
      return reply("Invalid notification destination");
    if (
      where !== "dm" &&
      (!guild ||
        !(await one(
          env,
          "SELECT channel_id FROM server_channels WHERE guild_id=?",
          guild,
        )))
    )
      return reply(
        "Server notifications require a server with a channel configured using /setchannel",
      );
    // Cache mutating interaction IDs, so Discord retries cannot toggle a subscription twice.
    const id = `discord:${data.id}`;
    requireValue(typeof data.id === "string", "Missing interaction ID");
    const results = await env.DB.batch([
      statement(
        env,
        `INSERT INTO notification_subscriptions(discord_user_id,username,username_lower,notify_type,guild_id)
        SELECT ?,?,?,?,? WHERE NOT EXISTS(SELECT 1 FROM webhook_events WHERE id=?)
        ON CONFLICT(discord_user_id,username_lower) DO UPDATE SET enabled=1-enabled,notify_type=excluded.notify_type,guild_id=excluded.guild_id`,
        user,
        username,
        username.toLowerCase(),
        where,
        where === "dm" ? null : guild,
        id,
      ),
      statement(
        env,
        "INSERT OR IGNORE INTO webhook_events(id,created_at) VALUES(?,?)",
        id,
        now(),
      ),
      statement(
        env,
        "SELECT enabled FROM notification_subscriptions WHERE discord_user_id=? AND username_lower=?",
        user,
        username.toLowerCase(),
      ),
    ]);
    return reply(
      `${(results[2].results[0] as any).enabled ? "Subscribed to" : "Unsubscribed from"} notifications on username **${username}**`,
    );
  }
  if (name === "list") {
    const subs = await rows(
      env,
      "SELECT username FROM notification_subscriptions WHERE discord_user_id=? AND enabled=1 ORDER BY created_at LIMIT 50",
      user,
    );
    return reply(
      subs.length
        ? subs.map((s) => `• ${s.username}`).join("\n")
        : "No active subscriptions. Use /notify to subscribe.",
    );
  }
  if (name === "search") {
    const username = option("username");
    if (typeof username !== "string" || !username.trim())
      return reply("Please provide a username");
    const limit =
      option("results") === "all"
        ? 10
        : Math.max(1, Math.min(10, Number(option("results") || 1)));
    const results = await search(env, {
      search_query: username,
      similarity_threshold: 1,
      result_limit: limit,
    });
    return reply(
      results.length
        ? results
            .map(
              (r) =>
                `**${r.streamer_display_name}** — <t:${Math.floor(Date.parse(r.actual_timestamp) / 1000)}:f> — ${r.vod_url}`,
            )
            .join("\n")
        : `No results found for **${username}**`,
    );
  }
  return reply("Unknown command");
}
async function discordApi(env: Env, path: string, data: unknown): Promise<any> {
  const response = await external(env, `https://discord.com/api/v10/${path}`, {
    method: "POST",
    headers: {
      Authorization: `Bot ${env.DISCORD_BOT_TOKEN}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(data),
  });
  return response.json();
}
export async function notify(env: Env, id: string) {
  const outbox = await one(
    env,
    "SELECT sent_at FROM notification_outbox WHERE detection_id=?",
    id,
  );
  if (!outbox || outbox.sent_at) return;
  if (env.ENVIRONMENT !== "production") {
    await statement(
      env,
      "UPDATE notification_outbox SET sent_at=? WHERE detection_id=?",
      now(),
      id,
    ).run();
    return;
  }
  const detection = await one(
    env,
    "SELECT * FROM detection_search WHERE detection_id=?",
    id,
  );
  if (!detection) {
    await statement(
      env,
      "UPDATE notification_outbox SET sent_at=? WHERE detection_id=?",
      now(),
      id,
    ).run();
    return;
  }
  const subs = await rows(
    env,
    "SELECT * FROM notification_subscriptions WHERE enabled=1 AND username_lower=?",
    detection.username_lower,
  );
  const destinations = new Map<
    string,
    { channel?: string; user?: string; users: string[] }
  >();
  for (const sub of subs) {
    if (sub.notify_type !== "server")
      destinations.set(`dm:${sub.discord_user_id}`, {
        user: sub.discord_user_id,
        users: [sub.discord_user_id],
      });
    if (sub.notify_type !== "dm" && sub.guild_id) {
      const channel = await one(
        env,
        "SELECT channel_id FROM server_channels WHERE guild_id=?",
        sub.guild_id,
      );
      if (channel) {
        const key = `channel:${channel.channel_id}`,
          dest = destinations.get(key) || {
            channel: channel.channel_id,
            users: [] as string[],
          };
        dest.users.push(sub.discord_user_id);
        destinations.set(key, dest);
      }
    }
  }
  for (const [destination, target] of destinations) {
    if (
      (
        await one(
          env,
          "SELECT sent_at FROM notification_deliveries WHERE detection_id=? AND destination=?",
          id,
          destination,
        )
      )?.sent_at
    )
      continue;
    let channel = target.channel;
    if (target.user)
      channel = (
        await discordApi(env, "users/@me/channels", {
          recipient_id: target.user,
        })
      ).id;
    if (!channel) throw new Error("Discord did not return a channel");
    const content = `👻🚨 New matchup found!\n**${detection.streamer_display_name}** vs **${detection.username}**\n<t:${Math.floor(Date.parse(detection.actual_timestamp) / 1000)}:f>\n${detection.vod_url}${target.channel ? "\n" + target.users.map((u) => `<@${u}>`).join(" ") : ""}`;
    // Stable nonce suppresses short-term retries following an ambiguous HTTP response.
    const hash = await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(`${id}:${destination}`),
    );
    const nonce = Array.from(new Uint8Array(hash).slice(0, 12), (b) =>
      b.toString(16).padStart(2, "0"),
    ).join("");
    await discordApi(env, `channels/${channel}/messages`, {
      content,
      allowed_mentions: { parse: [] },
      nonce,
      enforce_nonce: true,
    });
    await statement(
      env,
      "INSERT OR IGNORE INTO notification_deliveries(detection_id,destination,sent_at) VALUES(?,?,?)",
      id,
      destination,
      now(),
    ).run();
  }
  await env.DB.batch([
    statement(
      env,
      "UPDATE notification_subscriptions SET notification_count=notification_count+1 WHERE username_lower=? AND discord_user_id IN(SELECT value FROM json_each(?)) AND EXISTS(SELECT 1 FROM notification_outbox WHERE detection_id=? AND sent_at IS NULL)",
      detection.username_lower,
      JSON.stringify([
        ...new Set([...destinations.values()].flatMap((d) => d.users)),
      ]),
      id,
    ),
    statement(
      env,
      "UPDATE notification_outbox SET sent_at=? WHERE detection_id=? AND sent_at IS NULL",
      now(),
      id,
    ),
  ]);
}
