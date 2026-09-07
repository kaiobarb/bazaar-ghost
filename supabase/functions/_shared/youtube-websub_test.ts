import {
  readBody,
  topic,
  validSignature,
  verification,
  videoIds,
} from "./youtube-websub.ts";

function assert(value: unknown): asserts value {
  if (!value) throw new Error("Assertion failed");
}

const channel = "UC0000000000000000000000";
const xml =
  `<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
<entry><yt:videoId>YouTube0001</yt:videoId><yt:channelId>${channel}</yt:channelId></entry></feed>`;

Deno.test("WebSub verifies exact raw bytes for both supported HMAC algorithms", async () => {
  const body = new TextEncoder().encode(xml);
  for (const [algorithm, hash] of [["sha1", "SHA-1"], ["sha256", "SHA-256"]]) {
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode("secret"),
      { name: "HMAC", hash },
      false,
      ["sign"],
    );
    const signature = Array.from(
      new Uint8Array(await crypto.subtle.sign("HMAC", key, body)),
    )
      .map((value) => value.toString(16).padStart(2, "0")).join("");
    assert(await validSignature(body, `${algorithm}=${signature}`, "secret"));
    assert(
      !await validSignature(
        new TextEncoder().encode(xml + " "),
        `${algorithm}=${signature}`,
        "secret",
      ),
    );
    assert(!await validSignature(body, `${algorithm}=${signature}`, "wrong"));
  }
  assert(!await validSignature(body, null, "secret"));
  assert(!await validSignature(body, "sha1=bad", "secret"));
});

Deno.test("WebSub accepts only the requested channel and actual granted lease", () => {
  const now = Date.now();
  const subscription = {
    account_id: "account",
    callback_token: "token",
    secret: "secret",
    requested_at: new Date(now - 1000).toISOString(),
    confirmed_at: null,
    lease_expires_at: null,
  };
  const url = new URL("https://example.test/callback");
  for (
    const [key, value] of Object.entries({
      "hub.mode": "subscribe",
      "hub.topic": topic(channel),
      "hub.lease_seconds": "600",
      "hub.challenge": "plain challenge",
    })
  ) url.searchParams.set(key, value);
  const result = verification(url, subscription, channel, now);
  assert(result?.challenge === "plain challenge");
  assert(Date.parse(result.expiresAt) === now + 600000);
  assert(
    !verification(url, { ...subscription, requested_at: null }, channel, now),
  );
  assert(!verification(url, subscription, "another-channel", now));
  assert(!verification(url, subscription, channel, now + 7200000));
  url.searchParams.set("hub.mode", "unsubscribe");
  assert(!verification(url, subscription, channel, now));
});

Deno.test("Atom parsing rejects mismatched accounts, invalid IDs and entities", () => {
  assert(JSON.stringify(videoIds(xml, channel)) === '["YouTube0001"]');
  for (
    const invalid of [
      xml.replace(channel, "other"),
      xml.replace("YouTube0001", "invalid"),
      '<!DOCTYPE feed [<!ENTITY x SYSTEM "file:///etc/passwd">]>' + xml,
      "<feed><entry></feed>",
    ]
  ) {
    let rejected = false;
    try {
      videoIds(invalid, channel);
    } catch {
      rejected = true;
    }
    assert(rejected);
  }
});

Deno.test("Callback body limit applies without Content-Length", async () => {
  assert(
    (await readBody(
      new Request("https://example.test", { method: "POST", body: xml }),
    )).length > 0,
  );
  let rejected = false;
  try {
    await readBody(
      new Request("https://example.test", { method: "POST", body: xml }),
      10,
    );
  } catch {
    rejected = true;
  }
  assert(rejected);
});
