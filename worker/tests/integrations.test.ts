import { env } from "cloudflare:workers";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import worker from "../index";
import { now, one, rows } from "../http";
import { Twitch } from "../twitch";
import { scheduled, processPending } from "../jobs";

beforeEach(async () => {
  vi.stubGlobal(
    "fetch",
    vi.fn(() => {
      throw new Error("Unexpected network request");
    }),
  );
  await env.DB.prepare(
    "INSERT INTO sfde_profiles(id,profile_name,crop_region) VALUES(1,'test','[0,0,1,1]')",
  ).run();
});
afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});
const hex = (buffer: ArrayBuffer) =>
  Array.from(new Uint8Array(buffer), (b) =>
    b.toString(16).padStart(2, "0"),
  ).join("");
it("verifies signed Twitch challenges and rejects stale or modified bodies", async () => {
  const raw = JSON.stringify({ challenge: "challenge" }),
    id = "unique-event",
    timestamp = now();
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(env.TWITCH_EVENTSUB_SECRET),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature =
    "sha256=" +
    hex(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(id + timestamp + raw),
      ),
    );
  const headers = {
    "Twitch-Eventsub-Message-Id": id,
    "Twitch-Eventsub-Message-Timestamp": timestamp,
    "Twitch-Eventsub-Message-Signature": signature,
    "Twitch-Eventsub-Message-Type": "webhook_callback_verification",
  };
  const request = (body: string) =>
    new Request("http://local/functions/v1/process-vod", {
      method: "POST",
      headers,
      body,
    });
  const response = await worker.fetch(request(raw), env);
  expect(await response.text()).toBe("challenge");
  expect((await worker.fetch(request(raw + " "), env)).status).toBe(403);
  headers["Twitch-Eventsub-Message-Timestamp"] = "2000-01-01T00:00:00Z";
  expect((await worker.fetch(request(raw), env)).status).toBe(403);
});
it("validates Discord signatures and makes subscription retries idempotent", async () => {
  const pair = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const publicKey = hex(
      (await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer,
    ),
    testEnv = { ...env, DISCORD_PUBLIC_KEY: publicKey };
  async function call(payload: any) {
    const raw = JSON.stringify(payload),
      timestamp = String(Math.floor(Date.now() / 1000));
    const signature = hex(
      await crypto.subtle.sign(
        "Ed25519",
        pair.privateKey,
        new TextEncoder().encode(timestamp + raw),
      ),
    );
    return worker.fetch(
      new Request("http://local/functions/v1/ghost-bot", {
        method: "POST",
        headers: {
          "X-Signature-Ed25519": signature,
          "X-Signature-Timestamp": timestamp,
        },
        body: raw,
      }),
      testEnv,
    );
  }
  expect(await (await call({ type: 1 })).json()).toEqual({ type: 1 });
  const interaction = {
    type: 2,
    id: "123",
    user: { id: "456" },
    data: {
      name: "notify",
      options: [
        { name: "bazaar_username", value: "Opponent" },
        { name: "where", value: "dm" },
      ],
    },
  };
  expect((await call(interaction)).status).toBe(200);
  expect((await call(interaction)).status).toBe(200);
  expect(
    (await one(env, "SELECT enabled FROM notification_subscriptions"))!.enabled,
  ).toBe(1);
  interaction.id = "124";
  await call(interaction);
  expect(
    (await one(env, "SELECT enabled FROM notification_subscriptions"))!.enabled,
  ).toBe(0);
  const denied = await call({
    type: 2,
    id: "125",
    guild_id: "g",
    member: { user: { id: "456" }, permissions: "0" },
    data: { name: "setchannel" },
  });
  expect((await denied.json<any>()).data.content).toContain("Manage Server");
});
it("catalogs exact Bazaar ranges and keeps user-controlled processing configuration", async () => {
  const jobs = {
    send: vi.fn().mockResolvedValue(undefined),
  } as unknown as Queue;
  const twitch = new Twitch({ ...env, JOBS: jobs, OUTBOUND_ENABLED: "true" });
  await env.DB.prepare(
    "INSERT INTO streamers(id,login,processing_enabled) VALUES(1,'old_login',0)",
  ).run();
  vi.spyOn(twitch, "helix").mockImplementation(async (endpoint) => {
    if (endpoint === "users")
      return {
        data: [{ id: "1", login: "new_login", display_name: "New Login" }],
      };
    if (endpoint === "streams") return { data: [] };
    if (endpoint === "search/categories")
      return {
        data: [
          { id: "wrong", name: "The Bazaar Extra" },
          { id: "bazaar", name: "The Bazaar" },
        ],
      };
    throw new Error("Unexpected endpoint");
  });
  const node = {
    id: "123",
    title: "Mixed games",
    lengthSeconds: 100,
    publishedAt: "2026-09-01T00:00:00Z",
    game: { id: "other" },
    moments: {
      edges: [
        {
          node: {
            positionMilliseconds: 0,
            details: { game: { id: "other", name: "Other" } },
          },
        },
        {
          node: {
            positionMilliseconds: 20000,
            details: { game: { id: "bazaar", name: "The Bazaar" } },
          },
        },
      ],
    },
  };
  vi.spyOn(twitch, "gql").mockResolvedValue({
    user: { videos: { edges: [{ node }], pageInfo: { hasNextPage: false } } },
  });
  await twitch.catalog(1);
  const streamer = await one(env, "SELECT * FROM streamers");
  expect(streamer!.login).toBe("new_login");
  expect(streamer!.processing_enabled).toBe(0);
  expect(
    JSON.parse(
      (await one(env, "SELECT bazaar_chapters FROM vods"))!.bazaar_chapters,
    ),
  ).toEqual([20, 100]);
  expect(await rows(env, "SELECT id FROM chunks")).toEqual([]);
  node.moments.edges = Array(25).fill(node.moments.edges[0]);
  await expect(twitch.catalog(1)).rejects.toThrow("25-chapter");
});
it("cron handlers enqueue bounded work and outbound-disabled installs remain idle", async () => {
  const send = vi.fn().mockResolvedValue(undefined),
    jobs = { send } as unknown as Queue;
  const controller = {
    cron: "0 2 * * *",
    scheduledTime: Date.now(),
    noRetry() {},
  };
  await scheduled(controller, {
    ...env,
    JOBS: jobs,
    OUTBOUND_ENABLED: "false",
  });
  expect(send).not.toHaveBeenCalled();
  await scheduled(controller, { ...env, JOBS: jobs, OUTBOUND_ENABLED: "true" });
  expect(send).toHaveBeenCalledWith({ type: "discover" });
});
it("public caching distinguishes request bodies and single-object response shapes", async () => {
  const testEnv = { ...env, ENVIRONMENT: "dev" };
  await env.DB.prepare(
    "INSERT INTO streamers(id,login) VALUES(1,'cache_test')",
  ).run();
  const call = (name: string, accept = "application/json") =>
    worker.fetch(
      new Request(
        `https://cache-test.local/rest/v1/streamers?login=eq.${name}`,
        { headers: { Accept: accept } },
      ),
      testEnv,
    );
  const many = await call("cache_test");
  expect(many.headers.get("cache-control")).toContain("max-age=30");
  expect(Array.isArray(await many.json())).toBe(true);
  const single = await call("cache_test", "application/vnd.pgrst.object+json");
  expect((await single.json<any>()).login).toBe("cache_test");
  expect(await (await call("missing")).json()).toEqual([]);
  for (const value of ["one", "two"]) {
    const response = await worker.fetch(
      new Request(
        "https://cache-test.local/rest/v1/rpc/fuzzy_search_detections",
        { method: "POST", body: JSON.stringify({ search_query: value }) },
      ),
      testEnv,
    );
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual([]);
  }
});
it("empty imported chapter lists cannot starve eligible VODs in the scheduler", async () => {
  await env.DB.prepare(
    "INSERT INTO streamers(id,login) VALUES(1,'scheduler_test')",
  ).run();
  for (let id = 1; id <= 5; id++) {
    await env.DB.prepare(
      "INSERT INTO vods(id,streamer_id,source_id,duration_seconds,published_at,bazaar_chapters,ready_for_processing) VALUES(?,1,?,12,?,?,1)",
    )
      .bind(
        id,
        String(id),
        id === 5 ? "2026-09-01T00:00:00Z" : "2026-09-02T00:00:00Z",
        id === 5 ? "[0,12]" : "[]",
      )
      .run();
  }
  const send = vi.fn().mockResolvedValue(undefined);
  await processPending({ ...env, JOBS: { send } as unknown as Queue });
  expect(send.mock.calls.map(([job]) => job)).toEqual([
    { type: "process", id: 5 },
  ]);
});
