import { one, rows, statement, requireValue } from "./http";
import { Twitch, type CatalogStats } from "./twitch";
import { dispatch, plan, recover } from "./processing";
import { notify } from "./discord";

export type Job = {
  type: string;
  id?: number | string;
  after?: number;
  cursor?: string;
  offset?: number;
  page?: number;
  catalogStats?: CatalogStats;
};
export async function enqueueCatalog(env: Env, after = 0) {
  const streamers = await rows(
    env,
    "SELECT id FROM streamers WHERE id>? ORDER BY id LIMIT 100",
    after,
  );
  for (const s of streamers) await env.JOBS.send({ type: "catalog", id: s.id });
  if (streamers.length === 100)
    await env.JOBS.send({ type: "catalog-all", after: streamers.at(-1)!.id });
}
export async function processPending(env: Env) {
  await recover(env);
  const vods = await rows(
    env,
    `SELECT v.id FROM vod_processing_context v WHERE v.processing_enabled=1 AND v.ready_for_processing=1 AND v.availability='available' AND json_array_length(v.bazaar_chapters)>0 AND v.status IN('pending','partial','failed') AND
    (NOT EXISTS(SELECT 1 FROM chunks WHERE vod_id=v.id) OR EXISTS(SELECT 1 FROM chunks WHERE vod_id=v.id AND status='pending')) ORDER BY v.published_at DESC LIMIT 3`,
  );
  for (const v of vods) await env.JOBS.send({ type: "process", id: v.id });
  const outbox = await rows(
    env,
    "SELECT detection_id FROM notification_outbox WHERE sent_at IS NULL LIMIT 100",
  );
  for (const d of outbox)
    await env.JOBS.send({ type: "notify", id: d.detection_id });
}
export async function clearDevStorage(env: Env, cursor?: string) {
  requireValue(
    env.ENVIRONMENT === "dev",
    "Weekly deletion is restricted to dev",
  );
  const page = await env.DETECTIONS.list({ limit: 1000, cursor });
  if (page.objects.length)
    await env.DETECTIONS.delete(page.objects.map((o) => o.key));
  if (page.truncated)
    await env.JOBS.send({ type: "clear-dev-storage", cursor: page.cursor });
}
const CHAT_QUERY = `query VideoCommentsByOffsetOrCursor($videoID: ID!, $contentOffsetSeconds: Int) {
 video(id:$videoID) { comments(contentOffsetSeconds:$contentOffsetSeconds) { edges { node { id contentOffsetSeconds createdAt commenter { login } message { fragments { text } } } } pageInfo { hasNextPage } } }
}`;
async function chat(env: Env, job: Job) {
  const vod = await one(
    env,
    "SELECT id,source_id FROM vods WHERE id=? AND source='twitch'",
    job.id,
  );
  if (!vod) return;
  const result = await new Twitch(env).gql(CHAT_QUERY, {
    videoID: vod.source_id,
    contentOffsetSeconds: job.offset || 0,
  });
  const comments = result.video?.comments;
  if (!comments) return;
  let offset = job.offset || 0;
  for (const edge of comments.edges) {
    const n = edge.node,
      text = n.message.fragments.map((f: any) => f.text).join("");
    offset = Math.max(offset, n.contentOffsetSeconds);
    if (/bazaar\s?ghost/i.test(text)) {
      await statement(
        env,
        "INSERT OR IGNORE INTO chat_mentions(id,vod_id,username,message,offset_seconds,created_at) VALUES(?,?,?,?,?,?)",
        n.id,
        vod.id,
        n.commenter?.login || "[deleted]",
        text,
        n.contentOffsetSeconds,
        n.createdAt,
      ).run();
      console.log(
        JSON.stringify({
          event: "chat_mention",
          vod_id: vod.id,
          comment_id: n.id,
        }),
      );
    }
  }
  if (comments.pageInfo.hasNextPage && comments.edges.length) {
    if ((job.page || 0) >= 499)
      throw new Error("Chat pagination reached 500 pages; incomplete search");
    requireValue(offset > (job.offset || 0), "Chat pagination did not advance");
    await env.JOBS.send({
      type: "chat",
      id: vod.id,
      offset: Math.floor(offset) + 1,
      page: (job.page || 0) + 1,
    });
  }
}
export async function handleJob(env: Env, job: Job) {
  const twitch = new Twitch(env);
  switch (job.type) {
    case "discover":
      return twitch.discover(job.cursor);
    case "subscribe":
      return twitch.ensureSubscription(Number(job.id));
    case "catalog":
      return twitch.catalog(
        Number(job.id),
        job.cursor,
        false,
        job.catalogStats,
      );
    case "catalog-all":
      return enqueueCatalog(env, job.after);
    case "availability":
      return twitch.availability(job.after);
    case "plan":
      return plan(env, Number(job.id));
    case "process":
      return dispatch(env, Number(job.id));
    case "notify":
      return notify(env, String(job.id));
    case "clear-dev-storage":
      return clearDevStorage(env, job.cursor);
    case "chat":
      return chat(env, job);
    case "chat-all": {
      const vods = await rows(
        env,
        "SELECT id FROM vods WHERE source='twitch' AND id>? AND published_at>=? AND availability='available' ORDER BY id LIMIT 100",
        job.after || 0,
        new Date(Date.now() - 86400_000).toISOString(),
      );
      for (const v of vods) await env.JOBS.send({ type: "chat", id: v.id });
      if (vods.length === 100)
        await env.JOBS.send({ type: "chat-all", after: vods.at(-1)!.id });
      return;
    }
    default:
      throw new Error(`Unknown job type: ${job.type}`);
  }
}
export async function scheduled(event: ScheduledController, env: Env) {
  if (env.OUTBOUND_ENABLED !== "true") {
    console.log(
      JSON.stringify({
        event: "schedule_skipped",
        reason: "outbound_disabled",
        cron: event.cron,
      }),
    );
    return;
  }
  if (event.cron === "*/3 * * * *") await processPending(env);
  else if (event.cron === "0 * * * *") await enqueueCatalog(env);
  else if (event.cron === "0 0,12 * * *")
    await env.JOBS.send({ type: "availability" });
  else if (event.cron === "0 2 * * *")
    await env.JOBS.send({ type: "discover" });
  else if (event.cron === "0 3 * * *")
    await env.JOBS.send({ type: "chat-all" });
  else if (event.cron === "0 10 * * 0" && env.ENVIRONMENT === "dev")
    await env.JOBS.send({ type: "clear-dev-storage" });
}
