import { env } from 'cloudflare:test';
import { expect, it } from 'vitest';
import worker from '../index';
import { retryVod } from '../admin';
import { one, rows, statement } from '../http';
import { plan } from '../processing';
import { saveVideo, upsertAccount } from '../platforms';

type Source = 'twitch' | 'youtube' | 'bilibili';
async function fixture(source: Source) {
  await statement(env, "INSERT INTO sfde_profiles(id,profile_name,crop_region) VALUES(1,'retry','[0,0,1,1]')").run();
  await statement(env, "INSERT INTO streamers(id,login) VALUES(1,'fixture')").run();
  let id: number, accountId: string | undefined;
  if (source === 'twitch') {
    await statement(env, "INSERT INTO vods(streamer_id,source_id,duration_seconds,ready_for_processing,bazaar_chapters) VALUES(1,'123',1900,1,'[0,1900]')").run();
    id = (await one<{ id: number }>(env, "SELECT id FROM vods WHERE source='twitch'"))!.id;
  } else {
    const account = await upsertAccount(env, { source, source_id: source === 'youtube' ? 'UC' + 'a'.repeat(22) : '12345',
      display_name: 'Independent creator', processing_enabled: true });
    accountId = account.id;
    const video = await saveVideo(env, { account_id: account.id, video: { source,
      source_id: source === 'youtube' ? 'abcdefghijk' : 'BV1234567890:123',
      ...(source === 'bilibili' ? { source_video_id: 'BV1234567890', source_part_id: '123', source_part_index: 1 } : {}),
      title: 'The Bazaar retry fixture', duration_seconds: 1900, bazaar_chapters: [0, 1900] } });
    id = video.id;
  }
  const chunks = await plan(env, id);
  expect(chunks).toHaveLength(2);
  await env.DB.batch(chunks.map((chunk, index) => statement(env,
    "UPDATE chunks SET status=?,frames_processed=?,detections_count=?,completed_at='2026-09-07T00:00:00.000Z' WHERE id=?",
    index ? 'failed' : 'completed', index ? 10 : 900, index ? 0 : 3, chunk.id)));
  return { id, accountId, chunks };
}
async function retry(id: number, mode = 'failed') {
  return worker.fetch(new Request('http://localhost/api/admin/retry-vod', { method: 'POST',
    headers: { Authorization: `Bearer ${env.ADMIN_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ vod_id: id, mode }) }), env);
}

it.each<Source>(['twitch', 'youtube', 'bilibili'])('retries failed %s chunks and preserves completed siblings', async source => {
  const { id, chunks } = await fixture(source);
  const completed = await one(env, 'SELECT * FROM chunks WHERE id=?', chunks[0].id);
  const response = await retry(id);
  expect(response.status, await response.clone().text()).toBe(200);
  expect(await response.json()).toMatchObject({ reset: 1, chunks: [{ id: chunks[1].id, status: 'pending' }] });
  expect(await one(env, 'SELECT * FROM chunks WHERE id=?', chunks[0].id)).toEqual(completed);
  const all = await retry(id, 'all');
  expect(all.status).toBe(200);
  expect(await all.json()).toMatchObject({ reset: 2 });
  expect(await rows(env, 'SELECT status FROM chunks WHERE vod_id=?', id)).toEqual([{ status: 'pending' }, { status: 'pending' }]);
});

it.each<Source>(['youtube', 'bilibili'])('uses the %s account processing flag independently of a linked Twitch streamer', async source => {
  const { id, accountId } = await fixture(source);
  await env.DB.batch([
    statement(env, 'UPDATE platform_accounts SET streamer_id=1 WHERE id=?', accountId),
    statement(env, 'UPDATE vods SET streamer_id=1 WHERE id=?', id),
    statement(env, 'UPDATE streamers SET processing_enabled=0 WHERE id=1'),
  ]);
  expect((await retry(id)).status).toBe(200);
  await env.DB.batch([
    statement(env, 'UPDATE platform_accounts SET processing_enabled=0 WHERE id=?', accountId),
    statement(env, 'UPDATE streamers SET processing_enabled=1 WHERE id=1'),
    statement(env, "UPDATE chunks SET status='failed' WHERE vod_id=?", id),
  ]);
  expect((await retry(id)).status).toBe(400);
  expect(await rows(env, 'SELECT status FROM chunks WHERE vod_id=?', id)).toEqual([{ status: 'failed' }, { status: 'failed' }]);
});

// Commit a competing write after the initial no-active-worker read has returned.
// This changes actual D1 state; only the timing of that write is controlled.
function afterWorkerCheck(action: () => Promise<unknown>) {
  let fired = false;
  return new Proxy(env.DB, { get(database, key) {
    if (key === 'prepare') return (sql: string) => {
      const original = database.prepare(sql);
      if (!sql.startsWith('SELECT id FROM chunks WHERE vod_id=?')) return original;
      const wrap = (prepared: D1PreparedStatement): D1PreparedStatement => new Proxy(prepared, { get(target, method) {
        if (method === 'bind') return (...args: unknown[]) => wrap(target.bind(...args));
        if (method === 'first') return async () => {
          const result = await target.first();
          if (!fired) { fired = true; await action(); }
          return result;
        };
        const value = Reflect.get(target, method);
        return typeof value === 'function' ? value.bind(target) : value;
      } });
      return wrap(original);
    };
    const value = Reflect.get(database, key);
    return typeof value === 'function' ? value.bind(database) : value;
  } });
}

it.each(['disable', 'unavailable', 'claim'])('rejects a racing %s before resetting any chunk', async change => {
  const { id, chunks } = await fixture('twitch');
  const completed = await one(env, 'SELECT * FROM chunks WHERE id=?', chunks[0].id);
  const database = afterWorkerCheck(async () => {
    if (change === 'disable') return statement(env, 'UPDATE streamers SET processing_enabled=0 WHERE id=1').run();
    if (change === 'unavailable') return statement(env, "UPDATE vods SET availability='unavailable' WHERE id=?", id).run();
    return statement(env, "UPDATE chunks SET status='processing',claim_token='racing-owner' WHERE id=?", chunks[1].id).run();
  });
  await expect(retryVod({ ...env, DB: database }, { vod_id: id, mode: 'all' })).rejects.toMatchObject({ status: 409 });
  expect(await one(env, 'SELECT * FROM chunks WHERE id=?', chunks[0].id)).toEqual(completed);
  expect((await one(env, 'SELECT status FROM chunks WHERE id=?', chunks[1].id))!.status).toBe(change === 'claim' ? 'processing' : 'failed');
  expect(await rows(env, 'SELECT * FROM mutation_checks')).toEqual([]);
});
