import { XMLParser, XMLValidator } from "npm:fast-xml-parser@5.3.8";

export interface YoutubeSubscription {
  account_id: string;
  callback_token: string;
  secret: string;
  requested_at: string | null;
  confirmed_at: string | null;
  lease_expires_at: string | null;
}

export function topic(channelId: string): string {
  return `https://www.youtube.com/feeds/videos.xml?channel_id=${channelId}`;
}

export function verification(
  url: URL,
  subscription: YoutubeSubscription,
  channelId: string,
  now = Date.now(),
): { challenge: string; expiresAt: string } | null {
  const requestedAt = Date.parse(subscription.requested_at || "");
  const seconds = Number(url.searchParams.get("hub.lease_seconds"));
  const challenge = url.searchParams.get("hub.challenge");
  if (
    url.searchParams.get("hub.mode") !== "subscribe" ||
    url.searchParams.get("hub.topic") !== topic(channelId) ||
    !challenge || challenge.length > 4096 ||
    !Number.isSafeInteger(seconds) || seconds <= 0 || seconds > 31536000 ||
    !Number.isFinite(requestedAt) || requestedAt > now ||
    now - requestedAt > 3600000
  ) return null;
  return { challenge, expiresAt: new Date(now + seconds * 1000).toISOString() };
}

export async function validSignature(
  body: Uint8Array,
  header: string | null,
  secret: string,
): Promise<boolean> {
  const match = /^(sha1|sha256)=([a-fA-F0-9]+)$/.exec(header || "");
  if (!match || match[2].length !== (match[1] === "sha1" ? 40 : 64)) {
    return false;
  }
  const bytes = Uint8Array.from(
    match[2].match(/../g)!,
    (hex) => parseInt(hex, 16),
  );
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: match[1] === "sha1" ? "SHA-1" : "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "HMAC",
    key,
    bytes,
    body as Uint8Array<ArrayBuffer>,
  );
}

export function videoIds(body: string, channelId: string): string[] {
  if (
    /<!DOCTYPE|<!ENTITY/i.test(body) || XMLValidator.validate(body) !== true
  ) {
    throw new Error("Invalid notification XML");
  }
  const parser = new XMLParser({
    removeNSPrefix: true,
    processEntities: false,
    parseTagValue: false,
  });
  const parsed = parser.parse(body);
  if (!parsed.feed) throw new Error("Expected an Atom feed");
  const entries = parsed.feed.entry == null
    ? []
    : Array.isArray(parsed.feed.entry)
    ? parsed.feed.entry
    : [parsed.feed.entry];
  if (entries.length > 100) throw new Error("Too many entries");
  return [
    ...new Set(entries.map((entry: Record<string, unknown>) => {
      if (
        entry.channelId !== channelId || typeof entry.videoId !== "string" ||
        !/^[A-Za-z0-9_-]{11}$/.test(entry.videoId)
      ) {
        throw new Error("Notification account/video mismatch");
      }
      return entry.videoId;
    })),
  ] as string[];
}

export async function readBody(
  req: Request,
  limit = 65536,
): Promise<Uint8Array> {
  const reader = req.body?.getReader();
  if (!reader) throw new Error("Missing notification body");
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > limit) {
      await reader.cancel();
      throw new Error("Notification body too large");
    }
    chunks.push(value);
  }
  const body = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.length;
  }
  return body;
}
