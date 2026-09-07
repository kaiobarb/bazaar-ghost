import { requireValue } from "./http";

export const sources = ["twitch", "youtube", "bilibili"] as const;
export type Source = typeof sources[number];
export function source(value: unknown = "twitch"): Source {
  requireValue(typeof value === "string" && sources.includes(value as Source), "Invalid source");
  return value as Source;
}
export function videoIdentity(platform: Source, value: unknown): string {
  requireValue(typeof value === "string" && ({
    twitch: /^[1-9][0-9]{0,24}$/,
    youtube: /^[A-Za-z0-9_-]{11}$/,
    bilibili: /^BV[A-Za-z0-9]{10}:[1-9][0-9]{0,24}$/,
  })[platform].test(value), "Invalid source video identity");
  return value;
}
export function accountIdentity(platform: Source, value: unknown): string {
  requireValue(typeof value === "string" && ({
    twitch: /^[1-9][0-9]{0,24}$/,
    youtube: /^UC[A-Za-z0-9_-]{22}$/,
    bilibili: /^[1-9][0-9]{0,24}$/,
  })[platform].test(value), "Invalid platform account identity");
  return value;
}
export function dispatchBranch(environment: string) {
  const branches: Record<string, string> = { dev: "dev", production: "main", validation: "codex/cloudflare-validation" };
  requireValue(Object.hasOwn(branches, environment), "Dispatch requires dev, production or validation environment");
  return branches[environment];
}
