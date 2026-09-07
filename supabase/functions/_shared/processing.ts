import { supabase } from "./supabase.ts";

export interface PendingChunk {
  chunk_id: string;
  vod_id: number;
  source_id: string;
}

export interface ProcessingPlan {
  vod_id: number;
  source_id: string;
  chunks: PendingChunk[];
  old_templates: boolean;
  profile: Record<string, unknown>;
}

export async function planProcessing(
  vodId?: number,
  sourceId?: string,
): Promise<ProcessingPlan | null> {
  const { data: chunks, error } = await supabase.rpc(
    "get_pending_chunks_for_vod",
    {
      p_vod_id: vodId ?? null,
      p_source_id: sourceId ?? null,
    },
  );
  if (error) throw new Error(`Failed to find chunks: ${error.message}`);
  if (!chunks?.length) return null;
  const { data: vod, error: vodError } = await supabase.from("vods")
    .select("published_at, streamers!inner(sfde_profiles!inner(*))")
    .eq("id", chunks[0].vod_id).single();
  if (vodError) {
    throw new Error(`Failed to load processing profile: ${vodError.message}`);
  }
  const streamer = Array.isArray(vod.streamers)
    ? vod.streamers[0]
    : vod.streamers;
  const profile = Array.isArray(streamer.sfde_profiles)
    ? streamer.sfde_profiles[0]
    : streamer.sfde_profiles;
  if (!profile) throw new Error("Missing SFDE profile");
  return {
    vod_id: chunks[0].vod_id,
    source_id: chunks[0].source_id,
    chunks,
    old_templates: vod.published_at != null &&
      Date.parse(vod.published_at) < Date.parse("2025-08-12T00:00:00Z"),
    profile,
  };
}

/** Claim only pending rows and dispatch bounded matrices; roll back failed dispatches. */
export async function dispatchProcessing(
  plan: ProcessingPlan,
): Promise<string[]> {
  const environment = Deno.env.get("ENV") || "production";
  if (!["dev", "production"].includes(environment)) {
    throw new Error("ENV must be dev or production");
  }
  const token = Deno.env.get("GITHUB_TOKEN");
  if (!token) throw new Error("GITHUB_TOKEN is required");
  const dispatched: string[] = [];
  for (let offset = 0; offset < plan.chunks.length; offset += 256) {
    const queuedAt = new Date().toISOString();
    const { data: claimed, error } = await supabase.from("chunks")
      .update({ status: "queued", queued_at: queuedAt })
      .in(
        "id",
        plan.chunks.slice(offset, offset + 256).map((chunk) => chunk.chunk_id),
      )
      .eq("status", "pending").select("id");
    if (error) throw new Error(`Failed to queue chunks: ${error.message}`);
    const ids = (claimed || []).map((chunk) => chunk.id);
    if (!ids.length) continue;
    try {
      const response = await fetch(
        "https://api.github.com/repos/liftaris/bazaar-ghost/actions/workflows/process-vod.yml/dispatches",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            Accept: "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            ref: environment === "dev" ? "dev" : "main",
            inputs: {
              vod_id: plan.source_id,
              chunk_uuids: JSON.stringify(ids),
              old_templates: String(plan.old_templates),
              sfde_profile: JSON.stringify(plan.profile),
              environment,
            },
          }),
          signal: AbortSignal.timeout(15000),
        },
      );
      if (!response.ok) {
        throw new Error(
          `GitHub dispatch failed: ${response.status} ${await response.text()}`,
        );
      }
      dispatched.push(...ids);
    } catch (error: any) {
      const { error: rollbackError } = await supabase.from("chunks")
        .update({ status: "pending", queued_at: null }).in("id", ids)
        .eq("status", "queued").eq("queued_at", queuedAt);
      if (rollbackError) {
        console.error(
          "Failed to roll back queued chunks:",
          rollbackError.message,
        );
      }
      throw error;
    }
  }
  return dispatched;
}
