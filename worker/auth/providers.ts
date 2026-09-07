import type { BetterAuthOptions } from "better-auth";
import type { DiscordProfile } from "better-auth/social-providers";
import { external, readBytes } from "../http";
import type { AuthEnv } from "./security";

async function profile(env: AuthEnv, url: string, headers: Record<string, string>) {
  const response = await external(env, url, { headers, redirect: "error" });
  const bytes = await readBytes(new Request(url, { method: "POST", headers: response.headers, body: response.body }), 65_536);
  const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("Invalid provider profile");
  return value as Record<string, unknown>;
}
const subject = (value: unknown): value is string => typeof value === "string" && /^[1-9][0-9]{0,24}$/.test(value);
function displayName(value: unknown, fallback: string) {
  return typeof value === "string" && value.length > 0 && value.length <= 100 && !/[\x00-\x1f\x7f]/.test(value) ? value : fallback;
}
export function availableProviders(env: AuthEnv) {
  return [
    ...(env.DISCORD_AUTH_CLIENT_ID && env.DISCORD_AUTH_CLIENT_SECRET ? ["discord" as const] : []),
    ...(env.TWITCH_AUTH_CLIENT_ID && env.TWITCH_AUTH_CLIENT_SECRET ? ["twitch" as const] : []),
  ];
}
export function providers(env: AuthEnv): BetterAuthOptions["socialProviders"] {
  return {
    ...(env.DISCORD_AUTH_CLIENT_ID && env.DISCORD_AUTH_CLIENT_SECRET ? { discord: {
      clientId: env.DISCORD_AUTH_CLIENT_ID, clientSecret: env.DISCORD_AUTH_CLIENT_SECRET,
      disableDefaultScope: true, scope: ["identify"], prompt: "consent" as const,
      getUserInfo: async (token: { accessToken?: string }) => {
        if (!token.accessToken) return null;
        const info = await profile(env, "https://discord.com/api/users/@me", { Authorization: `Bearer ${token.accessToken}` });
        if (!subject(info.id) || info.bot === true || info.system === true) return null;
        const name = displayName(info.global_name, displayName(info.username, `Discord ${info.id}`));
        const image = typeof info.avatar === "string" && /^(?:a_)?[a-f0-9]{32}$/.test(info.avatar)
          ? `https://cdn.discordapp.com/avatars/${info.id}/${info.avatar}.png` : null;
        // The account-key resolver consumes only the validated raw id. Preserve the full
        // provider record; optional Discord fields are not required by identity-only login.
        return { user: { name, image: image || undefined, email: `${info.id}@discord.bazaarghost.invalid`, emailVerified: false }, data: info as DiscordProfile };
      },
    } } : {}),
    ...(env.TWITCH_AUTH_CLIENT_ID && env.TWITCH_AUTH_CLIENT_SECRET ? { twitch: {
      clientId: env.TWITCH_AUTH_CLIENT_ID, clientSecret: env.TWITCH_AUTH_CLIENT_SECRET,
      disableDefaultScope: true, scope: [], claims: [],
      // The stock adapter decodes an ID token without checking its signature. Identity-only
      // login instead validates the server token's application and subject, then queries Helix.
      getUserInfo: async (token: { accessToken?: string }) => {
        if (!token.accessToken) return null;
        const proof = await profile(env, "https://id.twitch.tv/oauth2/validate", { Authorization: `OAuth ${token.accessToken}` });
        if (proof.client_id !== env.TWITCH_AUTH_CLIENT_ID || !subject(proof.user_id) || typeof proof.expires_in !== "number" || proof.expires_in <= 0) return null;
        const info = await profile(env, "https://api.twitch.tv/helix/users", { Authorization: `Bearer ${token.accessToken}`, "Client-Id": env.TWITCH_AUTH_CLIENT_ID! });
        if (!Array.isArray(info.data) || info.data.length !== 1 || !info.data[0] || info.data[0].id !== proof.user_id) return null;
        const user = info.data[0] as Record<string, unknown>;
        const name = displayName(user.display_name, `Twitch ${proof.user_id}`);
        let image: string | null = null;
        if (typeof user.profile_image_url === "string" && user.profile_image_url.length > 0 && user.profile_image_url.length <= 2048) {
          try {
            const url = new URL(user.profile_image_url);
            if (url.protocol === "https:" && url.hostname === "static-cdn.jtvnw.net" && !url.username && !url.password) image = url.href;
          } catch { /* An invalid optional avatar never changes the verified identity. */ }
        }
        return { user: { name, image: image || undefined, email: `${proof.user_id}@twitch.bazaarghost.invalid`, emailVerified: false },
          data: { sub: proof.user_id, preferred_username: name, picture: image || "", email: "", email_verified: false } };
      },
    } } : {}),
  };
}
