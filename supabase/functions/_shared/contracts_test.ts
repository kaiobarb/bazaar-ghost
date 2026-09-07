// deno-lint-ignore-file require-await
// Async fetch stubs intentionally return immediately without network access.
import { hasSecretKey } from "./auth.ts";
import { extractBazaarChapters } from "./chapters.ts";
import {
  batchCheckVodAvailability,
  verifyEventSubSignature,
} from "./twitch.ts";
import type { VideoChapter } from "./twitch.ts";

function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown): void {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${JSON.stringify(actual)} != ${JSON.stringify(expected)}`,
  );
}
function chapter(seconds: number, id: string, name = "Other"): VideoChapter {
  return {
    positionMilliseconds: seconds * 1000,
    type: "GAME_CHANGE",
    description: "",
    game: { id, name, displayName: name },
  };
}

Deno.test("internal authentication never bypasses local requests", () => {
  const request = new Request("http://localhost/admin");
  assert(!hasSecretKey(request, "secret"));
  assert(
    !hasSecretKey(
      new Request(request, { headers: { apikey: "secret" } }),
      undefined,
    ),
  );
  assert(
    hasSecretKey(
      new Request(request, { headers: { apikey: "secret" } }),
      "secret",
    ),
  );
  assert(
    hasSecretKey(
      new Request(request, { headers: { authorization: "Bearer secret" } }),
      "secret",
    ),
  );
  assert(
    !hasSecretKey(
      new Request(request, { headers: { authorization: "Bearer public" } }),
      "secret",
    ),
  );
});

Deno.test("chapter planning sorts, clamps and merges only adjacent Bazaar ranges", () => {
  equal(
    extractBazaarChapters(
      [
        chapter(70, "other"),
        chapter(0, "bazaar"),
        chapter(20, "bazaar"),
        chapter(100, "bazaar"),
      ],
      120,
      "bazaar",
    ),
    [0, 70, 100, 120],
  );
  equal(extractBazaarChapters([chapter(150, "bazaar")], 120, "bazaar"), []);
  equal(
    extractBazaarChapters(
      [chapter(0, "other", "Bazaar Tycoon")],
      120,
      "bazaar",
    ),
    [],
  );
});

Deno.test("Twitch outages do not become false unavailable results", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    if (String(input).includes("oauth2/token")) {
      return Response.json({ access_token: "test", expires_in: 3600 });
    }
    return new Response("upstream failure", { status: 503 });
  };
  try {
    let failed = false;
    try {
      await batchCheckVodAvailability(["1", "2"]);
    } catch {
      failed = true;
    }
    assert(failed);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("Twitch batches preserve repeated id query parameters", async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (input) => {
    const url = new URL(String(input));
    if (url.pathname.includes("oauth2")) {
      return Response.json({ access_token: "test", expires_in: 3600 });
    }
    equal(url.searchParams.getAll("id"), ["1", "2"]);
    return Response.json({ data: [{ id: "2" }] });
  };
  try {
    equal(await batchCheckVodAvailability(["1", "2"]), {
      "1": false,
      "2": true,
    });
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test("EventSub requires a current timestamp and valid signature", async () => {
  const timestamp = new Date().toISOString();
  const body = "{}";
  const secret = "test-secret";
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode("id" + timestamp + body),
  );
  const signature = "sha256=" +
    [...new Uint8Array(digest)].map((value) =>
      value.toString(16).padStart(2, "0")
    ).join("");
  assert(
    await verifyEventSubSignature("id", timestamp, body, signature, secret),
  );
  assert(
    !await verifyEventSubSignature(
      "id",
      timestamp,
      "different",
      signature,
      secret,
    ),
  );
  assert(
    !await verifyEventSubSignature(
      "id",
      "2000-01-01T00:00:00Z",
      body,
      signature,
      secret,
    ),
  );
  assert(
    !await verifyEventSubSignature("id", "invalid", body, signature, secret),
  );
});
