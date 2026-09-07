import {
  HttpError,
  integer,
  now,
  one,
  requireValue,
  rows,
  statement,
  uuid,
  decodeRow,
  external,
} from "./http";

export function normalizeRanges(
  input: unknown,
  duration: number,
): [number, number][] {
  requireValue(
    Array.isArray(input) && input.length % 2 === 0,
    "Invalid Bazaar chapters",
  );
  const ranges: [number, number][] = [];
  for (let i = 0; i < input.length; i += 2) {
    integer(input[i], "chapter start");
    integer(input[i + 1], "chapter end");
    const start = Math.min(duration, input[i]),
      end = Math.min(duration, input[i + 1]);
    requireValue(end >= start, "Reversed chapter");
    if (end > start) ranges.push([start, end]);
  }
  const merged: [number, number][] = [];
  for (const [start, end] of ranges.sort((a, b) => a[0] - b[0])) {
    const last = merged.at(-1);
    if (last && start <= last[1]) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  }
  return merged;
}
export function missingChunks(
  ranges: [number, number][],
  existing: [number, number][],
): [number, number][] {
  const missing: [number, number][] = [];
  for (const [start, end] of ranges) {
    let cursor = start;
    for (const [a, b] of [...existing].sort((a, b) => a[0] - b[0])) {
      if (b <= cursor || a >= end) continue;
      while (cursor < Math.min(a, end)) {
        const next = Math.min(cursor + 1800, a, end);
        missing.push([cursor, next]);
        cursor = next;
      }
      cursor = Math.max(cursor, b);
    }
    while (cursor < end) {
      const next = Math.min(cursor + 1800, end);
      missing.push([cursor, next]);
      cursor = next;
    }
  }
  return missing;
}
export async function vodDetails(
  env: Env,
  sourceId: string,
): Promise<Record<string, any>> {
  const vod = await one(
    env,
    "SELECT v.*,s.processing_enabled,s.sfde_profile_id FROM vods v JOIN streamers s ON s.id=v.streamer_id WHERE source_id=?",
    sourceId,
  );
  if (!vod) throw new HttpError(404, "VOD not found");
  const profile = await one(
    env,
    "SELECT * FROM sfde_profiles WHERE id=?",
    vod.sfde_profile_id,
  );
  return {
    ...decodeRow(vod),
    streamers: {
      processing_enabled: Boolean(vod.processing_enabled),
      sfde_profiles: profile && decodeRow(profile),
    },
  };
}
export async function plan(
  env: Env,
  vodId: number,
): Promise<Record<string, any>[]> {
  const vod = await one(
    env,
    "SELECT v.*,s.processing_enabled FROM vods v JOIN streamers s ON s.id=v.streamer_id WHERE v.id=?",
    vodId,
  );
  if (
    !vod ||
    !vod.processing_enabled ||
    !vod.ready_for_processing ||
    vod.availability !== "available"
  )
    return [];
  // Retry a concurrent planner's overlap conflict by reading its committed intervals.
  for (let attempt = 0; attempt < 3; attempt++) {
    const existing = await rows(
      env,
      "SELECT start_seconds,end_seconds,chunk_index FROM chunks WHERE vod_id=? ORDER BY start_seconds",
      vodId,
    );
    const gaps = missingChunks(
      normalizeRanges(JSON.parse(vod.bazaar_chapters), vod.duration_seconds),
      existing.map((c) => [c.start_seconds, c.end_seconds]),
    );
    const index = existing.reduce((m, c) => Math.max(m, c.chunk_index), -1) + 1;
    if (!gaps.length) break;
    try {
      await env.DB.batch([
        ...gaps.map(([a, b], i) =>
          statement(
            env,
            "INSERT INTO chunks(id,vod_id,start_seconds,end_seconds,chunk_index) VALUES(?,?,?,?,?)",
            crypto.randomUUID(),
            vodId,
            a,
            b,
            index + i,
          ),
        ),
        statement(
          env,
          "UPDATE vods SET status=CASE WHEN status='completed' THEN 'partial' ELSE status END WHERE id=?",
          vodId,
        ),
      ]);
      break;
    } catch (error) {
      if (attempt === 2 || !String(error).includes("overlapping chunk"))
        throw error;
    }
  }
  return rows(
    env,
    "SELECT * FROM chunks WHERE vod_id=? AND status='pending' AND (scheduled_for IS NULL OR scheduled_for<=?) ORDER BY start_seconds",
    vodId,
    now(),
  );
}
export async function recover(env: Env) {
  const time = now();
  await statement(
    env,
    "UPDATE chunks SET status=CASE WHEN attempt_count<3 THEN 'pending' ELSE 'failed' END,claim_token=NULL,lease_expires_at=NULL,last_error='Lease expired',updated_at=? WHERE (status='processing' AND lease_expires_at<?) OR (status='queued' AND queued_at<?)",
    time,
    time,
    new Date(Date.now() - 35 * 60_000).toISOString(),
  ).run();
}
export async function dispatch(env: Env, vodId: number) {
  const pending = await plan(env, vodId);
  if (!pending.length) return [];
  requireValue(
    env.ENVIRONMENT === "dev" || env.ENVIRONMENT === "production",
    "Dispatch requires dev or production environment",
  );
  if (env.OUTBOUND_ENABLED !== "true" || !env.GITHUB_TOKEN)
    throw new HttpError(503, "GitHub dispatch is not configured");
  const vod = await one(env, "SELECT source_id FROM vods WHERE id=?", vodId);
  const details = await vodDetails(env, vod!.source_id);
  const configured = await one(
    env,
    "SELECT value FROM processing_config WHERE key='max_concurrent_chunks'",
  );
  const maxActive = integer(
    Number(configured?.value ?? 10),
    "max_concurrent_chunks",
    1,
    256,
  );
  const dispatched: string[] = [];
  for (let offset = 0; offset < pending.length; offset += 256) {
    const queuedAt = now();
    const claims = await env.DB.batch(
      pending
        .slice(offset, offset + 256)
        .map((c) =>
          statement(
            env,
            "UPDATE chunks SET status='queued',queued_at=?,updated_at=? WHERE id=? AND status='pending' AND (SELECT count(*) FROM chunks WHERE status IN('queued','processing'))<? RETURNING id",
            queuedAt,
            queuedAt,
            c.id,
            maxActive,
          ),
        ),
    );
    const ids = claims.flatMap((r) => r.results.map((c: any) => c.id));
    if (!ids.length) continue;
    try {
      await external(
        env,
        "https://api.github.com/repos/liftaris/bazaar-ghost/actions/workflows/process-vod.yml/dispatches",
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${env.GITHUB_TOKEN}`,
            Accept: "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "BazaarGhost",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            ref: env.ENVIRONMENT === "dev" ? "dev" : "main",
            inputs: {
              vod_id: vod!.source_id,
              chunk_uuids: JSON.stringify(ids),
              queued_at: queuedAt,
              old_templates: String(
                Date.parse(details.published_at) <
                  Date.parse("2025-08-12T00:00:00Z"),
              ),
              sfde_profile: JSON.stringify(details.streamers.sfde_profiles),
              environment: env.ENVIRONMENT,
            },
          }),
        },
      );
      dispatched.push(...ids);
    } catch (error) {
      await env.DB.batch(
        ids.map((id) =>
          statement(
            env,
            "UPDATE chunks SET status='pending',queued_at=NULL WHERE id=? AND status='queued' AND queued_at=?",
            id,
            queuedAt,
          ),
        ),
      );
      throw error;
    }
  }
  return dispatched;
}
export async function claim(
  env: Env,
  id: string,
  queuedAt: string | null = null,
) {
  requireValue(
    queuedAt === null ||
      (typeof queuedAt === "string" && Number.isFinite(Date.parse(queuedAt))),
    "Invalid dispatch timestamp",
  );
  const token = crypto.randomUUID(),
    time = now();
  const chunk = await one(
    env,
    `UPDATE chunks SET status='processing',claim_token=?,attempt_count=attempt_count+1,started_at=?,updated_at=?,lease_expires_at=?,last_error=NULL,completed_at=NULL
    WHERE id=? AND status IN('pending','queued') AND (? IS NULL OR (status='queued' AND queued_at=?)) AND EXISTS(SELECT 1 FROM vods v JOIN streamers s ON s.id=v.streamer_id WHERE v.id=chunks.vod_id AND s.processing_enabled=1 AND v.ready_for_processing=1 AND v.availability='available') RETURNING id`,
    token,
    time,
    time,
    new Date(Date.now() + 35 * 60_000).toISOString(),
    uuid(id),
    queuedAt,
    queuedAt,
  );
  return { claimed: Boolean(chunk), claim_token: chunk ? token : null };
}
export async function owned(env: Env, id: string, token: string | null) {
  if (!token) throw new HttpError(409, "Claim token required");
  const chunk = await one(
    env,
    "SELECT c.*,v.source_id,s.login AS streamer FROM chunks c JOIN vods v ON v.id=c.vod_id JOIN streamers s ON s.id=v.streamer_id WHERE c.id=? AND c.claim_token=? AND c.status='processing' AND c.lease_expires_at>?",
    uuid(id),
    token,
    now(),
  );
  if (!chunk)
    throw new HttpError(
      409,
      "Chunk claim expired or belongs to another runner",
    );
  return chunk;
}
export async function updateChunk(
  env: Env,
  id: string,
  token: string | null,
  data: Record<string, any>,
) {
  await owned(env, id, token);
  requireValue(
    ["processing", "completed", "failed"].includes(data.status),
    "Invalid chunk status",
  );
  const changes: Record<string, any> = {
    status: data.status,
    updated_at: now(),
  };
  for (const field of [
    "frames_processed",
    "detections_count",
    "processing_duration_ms",
  ])
    if (data[field] != null) changes[field] = integer(data[field], field);
  if (data.quality != null) {
    requireValue(
      /^(360|480|720|1080)p(60)?$/.test(data.quality),
      "Invalid quality",
    );
    changes.quality = data.quality;
  }
  if (data.error != null)
    changes.last_error = String(data.error).slice(0, 2000);
  if (data.status !== "processing") {
    changes.lease_expires_at = null;
    changes.completed_at = data.status === "completed" ? now() : null;
  }
  const result = await statement(
    env,
    `UPDATE chunks SET ${Object.keys(changes)
      .map((k) => `${k}=?`)
      .join(
        ",",
      )} WHERE id=? AND claim_token=? AND status='processing' AND lease_expires_at>?`,
    ...Object.values(changes),
    id,
    token,
    now(),
  ).run();
  if (!result.meta.changes) throw new HttpError(409, "Lost chunk claim");
  return { updated: true };
}
