import { env, applyD1Migrations } from "cloudflare:test";
import { beforeEach } from "vitest";

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
beforeEach(async () => {
  // Explicit cleanup avoids resetting the runtime's own Durable Objects between tests.
  const tables = [
    "chat_mentions",
    "notification_deliveries",
    "notification_outbox",
    "detections",
    "search_grams",
    "search_names",
    "chunks",
    "vods",
    "notification_subscriptions",
    "server_channels",
    "streamers",
    "sfde_profiles",
    "processing_config",
    "cataloger_runs",
    "webhook_events",
  ];
  await env.DB.batch(
    tables.map((table) => env.DB.prepare(`DELETE FROM ${table}`)),
  );
  for (const bucket of [env.DETECTIONS, env.LOGS]) {
    const page = await bucket.list();
    if (page.objects.length)
      await bucket.delete(page.objects.map((object) => object.key));
  }
});
