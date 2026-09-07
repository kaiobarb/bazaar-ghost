import { env } from "cloudflare:workers";
import { vi } from "vitest";
import { authRoute, authenticated, type AuthEnv } from "../auth";

export const ORIGIN = "https://auth-validation.example.org";
export const authEnv = (): AuthEnv => ({ ...env, ENVIRONMENT: "validation", OUTBOUND_ENABLED: "true", PUBLIC_URL: ORIGIN,
  CORS_ORIGINS: ORIGIN, AUTH_ENABLED: "true", AUTH_SECRET: "disposable-local-test-secret-not-valid-in-hosted-environments-44",
  DISCORD_AUTH_CLIENT_ID: "discord-client", DISCORD_AUTH_CLIENT_SECRET: "fixture-discord-secret",
  TWITCH_AUTH_CLIENT_ID: "twitch-client", TWITCH_AUTH_CLIENT_SECRET: "fixture-twitch-secret" });
export const cookies = (response: Response) => response.headers.getSetCookie().map(v => v.split(";")[0]).join("; ");
export const mergeCookies = (...values: string[]) => [...new Map(values.flatMap(value => value.split(";").filter(Boolean).map(pair => {
  const i = pair.indexOf("="); return [pair.slice(0, i).trim(), pair.slice(i + 1)] as const;
}))).entries()].map(([key, value]) => `${key}=${value}`).join("; ");
export function request(path: string, data?: unknown, cookie = "", csrfToken = "", origin = ORIGIN) {
  return new Request(ORIGIN + "/api/auth" + path, { method: data === undefined ? "GET" : "POST",
    headers: { Origin: origin, "Content-Type": "application/json", Cookie: cookie, "X-CSRF-Token": csrfToken, "CF-Connecting-IP": "192.0.2.1" },
    body: data === undefined ? undefined : JSON.stringify(data) });
}
export function mockProviders() {
  const subject = { discord: "100000000000000001", twitch: "12345" };
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL) => {
    const url = input instanceof Request ? input.url : String(input);
    if (url === "https://discord.com/api/oauth2/token") return Response.json({ access_token: "fixture-discord-token", refresh_token: "fixture-discord-refresh", token_type: "Bearer", expires_in: 3600, scope: "identify" });
    if (decodeURIComponent(url) === "https://discord.com/api/users/@me") return Response.json({ id: subject.discord, username: "fixture-user", global_name: "Fixture User", avatar: null, discriminator: "0", email: null, verified: false });
    if (url === "https://id.twitch.tv/oauth2/token") return Response.json({ access_token: "fixture-twitch-token", refresh_token: "fixture-twitch-refresh", token_type: "Bearer", expires_in: 3600, scope: [] });
    if (url === "https://id.twitch.tv/oauth2/validate") return Response.json({ client_id: "twitch-client", user_id: subject.twitch, expires_in: 3600, scopes: [] });
    if (url === "https://api.twitch.tv/helix/users") return Response.json({ data: [{ id: subject.twitch, display_name: "Fixture Twitch", profile_image_url: "https://static-cdn.jtvnw.net/fixture.png" }] });
    throw new Error("Unexpected mocked upstream path: " + new URL(url).pathname);
  }));
  return subject;
}
export async function start(provider = "discord", cookie = "", linking = false) {
  const identity = linking ? await authenticated(request("/session", undefined, cookie), authEnv()) : null;
  const response = await authRoute(request(linking ? "/link-social" : "/sign-in/social", { provider, callbackURL: ORIGIN + "/done" }, cookie, identity?.csrfToken), authEnv());
  if (response.status !== 200) throw new Error("Unable to start test login: " + response.status + " " + await response.text());
  const result = await response.json() as { url: string };
  return { url: new URL(result.url), cookie: mergeCookies(cookie, cookies(response)) };
}
export async function complete(flow: Awaited<ReturnType<typeof start>>, provider = "discord", cookie = flow.cookie) {
  return authRoute(request(`/callback/${provider}?code=fixture-code&state=${encodeURIComponent(flow.url.searchParams.get("state")!)}`, undefined, cookie), authEnv());
}
export async function login(provider = "discord") {
  const response = await complete(await start(provider), provider);
  if (response.headers.get("Location") !== ORIGIN + "/done") throw new Error("Test login failed: " + response.status + " " + response.headers.get("Location") + " " + await response.text());
  const cookie = cookies(response), identity = await authenticated(request("/session", undefined, cookie), authEnv());
  return { response, cookie, identity };
}
