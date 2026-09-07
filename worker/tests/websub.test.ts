import { env } from "cloudflare:workers";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
import { now, one, rows, statement } from "../http";
import { renewSubscription, topic, validSignature, videoIds, youtubeWebhook } from "../youtube-websub";

const ACCOUNT = "10000000-0000-4000-8000-000000000001";
const OTHER = "10000000-0000-4000-8000-000000000002";
const CHANNEL = "UCabcdefghijklmnopqrstuv";
const TOKEN = "a".repeat(64), SECRET = "b".repeat(64);
const VIDEO = "abcdefghijk";
const hosted = () => ({ ...env, ENVIRONMENT: "validation", OUTBOUND_ENABLED: "true", PUBLIC_URL: "https://bazaarghost-validation.example.org" });
const hex = (buffer: ArrayBuffer) => Array.from(new Uint8Array(buffer), b => b.toString(16).padStart(2, "0")).join("");
function feed(video = VIDEO, channel = CHANNEL) {
  return `<feed xmlns="http://www.w3.org/2005/Atom" xmlns:yt="http://www.youtube.com/xml/schemas/2015"><entry><yt:videoId>${video}</yt:videoId><yt:channelId>${channel}</yt:channelId></entry></feed>`;
}
function callback(parameters: Record<string, string> = {}, token = TOKEN) {
  const url = new URL("https://bazaarghost-validation.example.org/functions/v1/youtube-webhook");
  url.search = new URLSearchParams({ account: ACCOUNT, token, ...parameters }).toString();
  return url.href;
}
function challenge(parameters: Record<string, string> = {}, token = TOKEN) {
  return new Request(callback({ "hub.mode": "subscribe", "hub.topic": topic(CHANNEL),
    "hub.challenge": "safe.challenge-123_+", "hub.lease_seconds": "86400", ...parameters }, token));
}
async function signature(bytes: Uint8Array, algorithm = "sha256", secret = SECRET) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    {name: "HMAC", hash: algorithm.replace("sha", "SHA-")}, false, ["sign"]);
  return algorithm + "=" + hex(await crypto.subtle.sign("HMAC", key, new Uint8Array(bytes)));
}
async function notification(xml = feed(), options: { token?: string; signature?: string; algorithm?: string } = {}) {
  return new Request(callback({}, options.token), { method: "POST", body: xml,
    headers: { "X-Hub-Signature": options.signature ?? await signature(new TextEncoder().encode(xml), options.algorithm) } });
}
async function pending() {
  await statement(env, "INSERT INTO youtube_websub_subscriptions(account_id,callback_token,secret,requested_at) VALUES(?,?,?,?)", ACCOUNT, TOKEN, SECRET, now()).run();
}
async function active() {
  await pending();
  expect((await youtubeWebhook(challenge(), env)).status).toBe(200);
}
beforeEach(async () => {
  vi.stubGlobal("fetch", vi.fn(() => { throw new Error("Unexpected network request"); }));
  await statement(env, "INSERT INTO sfde_profiles(id,profile_name,crop_region) VALUES(1,'websub','[0,0,1,1]')").run();
  await statement(env, "INSERT INTO platform_accounts(id,source,source_id,display_name,processing_enabled) VALUES(?,'youtube',?,'test',1)", ACCOUNT, CHANNEL).run();
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

it("consumes a challenge exactly once with a safe response and rejects duplicate parameters", async () => {
  await pending();
  const duplicated = new URL(challenge().url);
  duplicated.searchParams.append("hub.challenge", "other");
  expect((await youtubeWebhook(new Request(duplicated), env)).status).toBe(404);
  const responses = await Promise.all([youtubeWebhook(challenge(), env), youtubeWebhook(challenge(), env)]);
  expect(responses.map(r => r.status).sort()).toEqual([200,404]);
  const accepted = responses.find(r => r.status === 200)!;
  expect(await accepted.text()).toBe("safe.challenge-123_+");
  expect(accepted.headers.get("content-type")).toBe("text/plain; charset=utf-8");
  expect(accepted.headers.get("cache-control")).toBe("no-store");
  expect(accepted.headers.get("x-content-type-options")).toBe("nosniff");
  const saved = (await one(env, "SELECT * FROM youtube_websub_subscriptions"))!;
  expect(saved.requested_at).toBeNull();
  expect(Date.parse(saved.lease_expires_at)).toBeGreaterThan(Date.now());
  expect((await youtubeWebhook(challenge(), env)).status).toBe(404);
});
it.each<Record<string, string>>([
  {"hub.topic":"https://www.youtube.com/feeds/videos.xml?channel_id=UC0000000000000000000000"},
  {"hub.topic":topic(CHANNEL)+"&extra=1"}, {"hub.mode":"unsubscribe"}, {"hub.challenge":"<script>"},
  {"hub.lease_seconds":"0"}, {"hub.lease_seconds":"31536001"}, {"hub.lease_seconds":"1e3"}, {"hub.lease_seconds":"1.5"},
])("rejects malformed or unsolicited verification: %j", async parameters => {
  await pending();
  expect((await youtubeWebhook(challenge(parameters), env)).status).toBe(404);
  expect((await one(env, "SELECT confirmed_at FROM youtube_websub_subscriptions"))!.confirmed_at).toBeNull();
});
it("rejects stale/future pending intent, wrong capabilities and disabled accounts", async () => {
  await pending();
  for (const timestamp of [Date.now()-3_600_001, Date.now()+60_000]) {
    await statement(env, "UPDATE youtube_websub_subscriptions SET requested_at=?", new Date(timestamp).toISOString()).run();
    expect((await youtubeWebhook(challenge(), env)).status).toBe(404);
  }
  expect((await youtubeWebhook(challenge({}, "c".repeat(64)), env)).status).toBe(404);
  await statement(env, "UPDATE platform_accounts SET processing_enabled=0").run();
  expect((await youtubeWebhook(challenge(), env)).status).toBe(404);
});
it("denial clears pending/active intent, cannot be undone by an old challenge, and does not reset retry cooldown on replay", async () => {
  await active();
  const denial = () => new Request(callback({"hub.mode":"denied","hub.topic":topic(CHANNEL),"hub.reason":"sensitive upstream body"}));
  expect((await youtubeWebhook(denial(), env)).status).toBe(204);
  const saved = (await one(env, "SELECT * FROM youtube_websub_subscriptions"))!;
  expect(saved.confirmed_at).toBeNull(); expect(saved.requested_at).toBeNull();
  expect(saved.last_error).not.toContain("sensitive");
  expect((await youtubeWebhook(challenge(), env)).status).toBe(404);
  expect((await youtubeWebhook(await notification(), env)).status).toBe(403);
  expect(await renewSubscription(hosted(), ACCOUNT)).toEqual({requested:false});
  expect((await youtubeWebhook(denial(), env)).status).toBe(204);
  expect((await one(env,"SELECT lease_expires_at FROM youtube_websub_subscriptions"))!.lease_expires_at).toBe(saved.lease_expires_at);
});
it("authenticates exact raw bytes using supported hub algorithms", async () => {
  const bytes = new TextEncoder().encode(feed());
  for (const algorithm of ["sha1", "sha256", "sha384", "sha512"]) {
    const signed = await signature(bytes, algorithm);
    expect(await validSignature(bytes, signed, SECRET)).toBe(true);
    expect(await validSignature(new TextEncoder().encode(feed()+" "), signed, SECRET)).toBe(false);
  }
  for (const bad of [null, "sha256=xyz", "sha1="+"f".repeat(64), "md5="+"f".repeat(32), "sha256="+"f".repeat(64)+",sha1=abc"])
    expect(await validSignature(bytes, bad, SECRET)).toBe(false);
});
it("resolves namespace URIs, rejects spoofed/duplicate/nested IDs, and bounds XML", () => {
  expect(videoIds(feed(), CHANNEL)).toEqual([VIDEO]);
  expect(videoIds(feed().replaceAll("yt:", "alias:").replace("xmlns:yt", "xmlns:alias"), CHANNEL)).toEqual([VIDEO]);
  expect(videoIds(feed().replaceAll(VIDEO, `<![CDATA[${VIDEO}]]>`), CHANNEL)).toEqual([VIDEO]);
  expect(videoIds(feed().replace("</feed>",feed().match(/<entry>.*<\/entry>/)![0]+"</feed>"), CHANNEL)).toEqual([VIDEO]);
  const invalid = [
    feed().replace("http://www.youtube.com/xml/schemas/2015", "https://attacker.example/youtube"),
    feed().replace("http://www.w3.org/2005/Atom", "https://attacker.example/Atom"),
    feed().replace("<yt:channelId>", '<yt:channelId xmlns:yt="urn:evil">'),
    feed().replace("</entry>",`<yt:videoId>${VIDEO}</yt:videoId></entry>`),
    feed().replace(VIDEO,`<inner>${VIDEO}</inner>`),
    feed(VIDEO,"UC0000000000000000000000"), feed("short"),
    '<!DOCTYPE feed [<!ENTITY x "x">]>'+feed(),
    feed().replace("</feed>", "<x>".repeat(34)+"</x>".repeat(34)+"</feed>"),
    feed().replace("<entry>","<entry>".repeat(101)),
    feed().replace("</feed>",feed().match(/<entry>.*<\/entry>/)![0].repeat(100)+"</feed>"),
  ];
  for (const xml of invalid) expect(() => videoIds(xml, CHANNEL)).toThrow();
});
it("requires an active lease, valid HMAC, valid UTF-8/XML, and a bounded streaming body", async () => {
  await pending();
  expect((await youtubeWebhook(await notification(), env)).status).toBe(403);
  expect((await youtubeWebhook(challenge(), env)).status).toBe(200);
  expect((await youtubeWebhook(await notification(feed(),{signature:"sha256="+"0".repeat(64)}),env)).status).toBe(403);
  expect((await youtubeWebhook(await notification("<invalid>"),env)).status).toBe(400);
  const invalidUtf8 = new Uint8Array([255,254]);
  expect((await youtubeWebhook(new Request(callback(),{method:"POST",body:invalidUtf8,
    headers:{"X-Hub-Signature":await signature(invalidUtf8)}}),env)).status).toBe(400);
  const tooLarge = new ReadableStream({start(controller) { controller.enqueue(new Uint8Array(65_537)); controller.close(); }});
  expect((await youtubeWebhook(new Request(callback(),{method:"POST",body:tooLarge,duplex:"half"} as RequestInit),env)).status).toBe(413);
  await statement(env,"UPDATE youtube_websub_subscriptions SET lease_expires_at=?",new Date(Date.now()-1).toISOString()).run();
  expect((await youtubeWebhook(await notification(),env)).status).toBe(403);
  expect(await rows(env,"SELECT * FROM platform_ingestion_jobs")).toEqual([]);
});
it("deduplicates concurrent deliveries atomically and never wakes a completed job for a replay", async () => {
  await active();
  const requests = await Promise.all([notification(),notification()]);
  expect((await Promise.all(requests.map(r=>youtubeWebhook(r,env)))).map(r=>r.status)).toEqual([204,204]);
  expect(await rows(env,"SELECT source,kind,source_id,account_id,status FROM platform_ingestion_jobs")).toEqual([
    {source:"youtube",kind:"video",source_id:VIDEO,account_id:ACCOUNT,status:"pending"}]);
  expect((await rows(env,"SELECT * FROM youtube_websub_deliveries")).length).toBe(1);
  await statement(env,"UPDATE platform_ingestion_jobs SET status='completed',completed_at='2000-01-01T00:00:00.000Z'").run();
  expect((await youtubeWebhook(await notification(),env)).status).toBe(204);
  expect((await one(env,"SELECT status FROM platform_ingestion_jobs"))!.status).toBe("completed");
  expect((await youtubeWebhook(await notification(feed().replace("</entry>","<title>Changed title</title></entry>")),env)).status).toBe(204);
  expect((await one(env,"SELECT status FROM platform_ingestion_jobs"))!.status).toBe("pending");
});
it("does not requeue a processing job twice for identical bodies", async () => {
  await active();
  expect((await youtubeWebhook(await notification(),env)).status).toBe(204);
  await statement(env,"UPDATE platform_ingestion_jobs SET status='processing',rerun_requested=0").run();
  expect((await youtubeWebhook(await notification(),env)).status).toBe(204);
  expect((await one(env,"SELECT rerun_requested FROM platform_ingestion_jobs"))!.rerun_requested).toBe(0);
  expect((await youtubeWebhook(await notification(feed().replace("</entry>","<title>update</title></entry>")),env)).status).toBe(204);
  expect((await one(env,"SELECT rerun_requested FROM platform_ingestion_jobs"))!.rerun_requested).toBe(1);
});
it("does not steal an existing video's owner and rolls back its receipt and all sibling enqueues", async () => {
  await active();
  await statement(env,"INSERT INTO platform_accounts(id,source,source_id,display_name) VALUES(?,'youtube','UC0000000000000000000000','other')",OTHER).run();
  await statement(env,"INSERT INTO platform_ingestion_jobs(id,source,kind,source_id,account_id) VALUES(?,'youtube','video',?,?)",crypto.randomUUID(),VIDEO,OTHER).run();
  const xml=feed("12345678901").replace("</feed>",feed().match(/<entry>.*<\/entry>/)![0]+"</feed>");
  expect((await youtubeWebhook(await notification(xml),env)).status).toBe(409);
  expect(await rows(env,"SELECT source_id,account_id FROM platform_ingestion_jobs")).toEqual([{source_id:VIDEO,account_id:OTHER}]);
  expect(await rows(env,"SELECT * FROM youtube_websub_deliveries")).toEqual([]);
});
it("fences account disablement that races after the initial callback lookup", async () => {
  await active();
  const original=crypto.subtle.verify.bind(crypto.subtle);
  vi.spyOn(crypto.subtle,"verify").mockImplementation(async (...args) => {
    const result=await original(...args);
    await statement(env,"UPDATE platform_accounts SET processing_enabled=0 WHERE id=?",ACCOUNT).run();
    return result;
  });
  expect((await youtubeWebhook(await notification(),env)).status).toBe(409);
  expect(await rows(env,"SELECT * FROM youtube_websub_deliveries")).toEqual([]);
  expect(await rows(env,"SELECT * FROM platform_ingestion_jobs")).toEqual([]);
});
it("serializes renewals and submits only the isolated configured HTTPS callback", async () => {
  const calls: Array<URLSearchParams>=[];
  vi.stubGlobal("fetch",vi.fn(async (url:string, init:RequestInit) => {
    expect(url).toBe("https://pubsubhubbub.appspot.com/subscribe");
    calls.push(new URLSearchParams(init.body as URLSearchParams));
    return new Response(null,{status:202});
  }));
  const attempts=await Promise.all([renewSubscription(hosted(),ACCOUNT),renewSubscription(hosted(),ACCOUNT)]);
  expect(attempts.filter(a=>a.requested)).toHaveLength(1); expect(calls).toHaveLength(1);
  expect(calls[0].get("hub.topic")).toBe(topic(CHANNEL));
  const callbackUrl=new URL(calls[0].get("hub.callback")!);
  expect(callbackUrl.origin).toBe(hosted().PUBLIC_URL);
  expect(callbackUrl.searchParams.get("account")).toBe(ACCOUNT);
  const subscription=(await one(env,"SELECT * FROM youtube_websub_subscriptions"))!;
  expect(callbackUrl.searchParams.get("token")).toBe(subscription.callback_token);
  expect(calls[0].get("hub.secret")).toBe(subscription.secret);
  expect((await youtubeWebhook(challenge({},subscription.callback_token),env)).status).toBe(200);
  expect(await renewSubscription(hosted(),ACCOUNT)).toEqual({requested:false});
});
it("keeps polling usable when subscription requests fail and does not overwrite a raced verification", async () => {
  vi.stubGlobal("fetch",vi.fn(async (_url:string,init:RequestInit) => {
    const params=new URLSearchParams(init.body as URLSearchParams), cb=new URL(params.get("hub.callback")!);
    expect((await youtubeWebhook(challenge({},cb.searchParams.get("token")!),env)).status).toBe(200);
    throw new Error("network failed with sensitive request context");
  }));
  expect(await renewSubscription(hosted(),ACCOUNT)).toEqual({requested:false});
  const saved=(await one(env,"SELECT * FROM youtube_websub_subscriptions"))!;
  expect(saved.confirmed_at).not.toBeNull(); expect(saved.last_error).toBeNull();
});
it("preserves pending intent after ambiguous HTTP failure, throttles retries, and rotates stale capabilities", async () => {
  expect(await renewSubscription(hosted(),ACCOUNT)).toEqual({requested:false});
  const first=(await one(env,"SELECT * FROM youtube_websub_subscriptions"))!;
  expect(first.last_error).toBe("Subscription request failed; polling remains active");
  expect(await renewSubscription(hosted(),ACCOUNT)).toEqual({requested:false});
  expect(fetch).toHaveBeenCalledTimes(1);
  await statement(env,"UPDATE youtube_websub_subscriptions SET requested_at=?",new Date(Date.now()-3_600_001).toISOString()).run();
  await renewSubscription(hosted(),ACCOUNT);
  const next=(await one(env,"SELECT * FROM youtube_websub_subscriptions"))!;
  expect(next.callback_token).not.toBe(first.callback_token);
  expect((await youtubeWebhook(challenge({},first.callback_token),env)).status).toBe(404);
  expect((await youtubeWebhook(challenge({},next.callback_token),env)).status).toBe(200);
});
it("does not subscribe locally, with outbound disabled, for disabled/non-YouTube accounts, or to unsafe callback origins", async () => {
  expect(await renewSubscription(env,ACCOUNT)).toEqual({requested:false});
  await statement(env,"UPDATE platform_accounts SET processing_enabled=0 WHERE id=?",ACCOUNT).run();
  expect(await renewSubscription(hosted(),ACCOUNT)).toEqual({requested:false});
  expect(await rows(env,"SELECT * FROM youtube_websub_subscriptions")).toEqual([]);
  for(const PUBLIC_URL of ["http://example.org","https://localhost","https://user:password@example.org","https://example.org/path","https://example.org/?token=secret"])
    await expect(renewSubscription({...hosted(),PUBLIC_URL},ACCOUNT)).rejects.toThrow("public HTTPS origin");
  expect(fetch).not.toHaveBeenCalled();
});
