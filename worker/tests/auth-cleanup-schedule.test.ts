import { env } from 'cloudflare:test';
import { afterEach, expect, it, vi } from 'vitest';
import { cleanupAuth } from '../auth';
import { scheduled } from '../jobs';

afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); });

it.each([
  ['false', 'false'], ['false', 'true'], ['true', 'false'], ['true', 'true'],
])('runs one bounded cleanup per minute with outbound=%s and auth=%s', async (outbound, auth) => {
  const future = Date.now() + 3_600_000;
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO auth_rate_limits(key,count,expiresAt)
      SELECT value,1,0 FROM json_each(?)`).bind(JSON.stringify(Array.from({ length: 501 }, (_, i) => `expired-${i}`))),
    env.DB.prepare("INSERT INTO auth_rate_limits(key,count,expiresAt) VALUES('live-private-key',7,?)").bind(future),
  ]);
  const fetch = vi.fn(() => { throw new Error('Cleanup must not call a provider'); });
  vi.stubGlobal('fetch', fetch);
  const send = vi.fn(), sendBatch = vi.fn();
  const testEnv = { ...env, ENVIRONMENT: 'validation', OUTBOUND_ENABLED: outbound, AUTH_ENABLED: auth,
    JOBS: { send, sendBatch } as unknown as Queue };
  const log = vi.spyOn(console, 'log').mockImplementation(() => {});
  const event = { cron: '* * * * *', scheduledTime: Date.now(), noRetry() {} };

  await scheduled(event, testEnv);
  expect(await env.DB.prepare('SELECT count(*) AS n FROM auth_rate_limits WHERE expiresAt=0').first()).toEqual({ n: 1 });
  expect(JSON.parse(log.mock.calls[0][0]).deleted_rows.auth_rate_limits).toBe(500);
  await scheduled({ ...event, scheduledTime: event.scheduledTime + 60_000 }, testEnv);
  expect((await env.DB.prepare('SELECT * FROM auth_rate_limits').all()).results)
    .toEqual([{ key: 'live-private-key', count: 7, expiresAt: future }]);
  expect(JSON.parse(log.mock.calls[1][0]).deleted_rows.auth_rate_limits).toBe(1);
  expect(log).toHaveBeenCalledTimes(2);
  expect(fetch).not.toHaveBeenCalled();
  expect(send).not.toHaveBeenCalled();
  expect(sendBatch).not.toHaveBeenCalled();
});

it('reports direct deletions separately from cascade work without logging private state', async () => {
  const old = new Date(Date.now() - 7_200_000).toISOString();
  const future = Date.now() + 3_600_000;
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO app_users(id,name,email,emailVerified,createdAt,updatedAt)
      VALUES('private-owner','Private Name','private@example.invalid',0,?,?),
      ('private-orphan','Private Orphan','orphan@example.invalid',0,?,?)`).bind(old, old, old, old),
    env.DB.prepare(`INSERT INTO user_accounts(id,accountId,providerId,userId,createdAt,updatedAt)
      VALUES('private-account','private-provider-subject','discord','private-owner',?,?)`).bind(old, old),
    env.DB.prepare(`INSERT INTO user_sessions(id,token,userId,expiresAt,createdAt,updatedAt)
      VALUES('private-session','private-session-token','private-owner',?,?,?)`).bind(old, old, old),
    env.DB.prepare(`INSERT INTO auth_flows(stateHash,provider,expiresAt)
      VALUES('private-expired-state-1','discord',0),('private-expired-state-2','twitch',0)`),
    // This unexpired linking flow disappears through the expired session's cascade.
    env.DB.prepare(`INSERT INTO auth_flows(stateHash,provider,linkUserId,linkSessionId,expiresAt)
      VALUES('private-cascaded-state','twitch','private-owner','private-session',?)`).bind(future),
    env.DB.prepare("INSERT INTO auth_rate_limits(key,count,expiresAt) VALUES('private-rate-key',3,0)"),
    env.DB.prepare(`INSERT INTO auth_verifications(id,identifier,value,expiresAt,createdAt,updatedAt)
      VALUES('private-verification','private-identifier','private-verification-value',?,?,?)`).bind(old, old, old),
  ]);
  const log = vi.spyOn(console, 'log').mockImplementation(() => {});
  await cleanupAuth(env);
  expect(log).toHaveBeenCalledTimes(1);
  const metrics = JSON.parse(log.mock.calls[0][0]);
  expect(metrics).toEqual({
    event: 'auth_cleanup',
    deleted_rows: { auth_flows: 2, auth_rate_limits: 1, auth_verifications: 1, user_sessions: 1, app_users: 1 },
    rows_read: expect.any(Number), rows_written: expect.any(Number), duration_ms: expect.any(Number),
  });
  expect(metrics.rows_read).toBeGreaterThan(0);
  expect(metrics.rows_written).toBeGreaterThanOrEqual(7);
  expect(metrics.duration_ms).toBeGreaterThanOrEqual(0);
  expect(log.mock.calls[0][0]).not.toContain('private');
  expect(await env.DB.prepare('SELECT count(*) AS n FROM auth_flows').first()).toEqual({ n: 0 });
  expect((await env.DB.prepare('SELECT id FROM app_users').all()).results).toEqual([{ id: 'private-owner' }]);
  expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
});

it('does not misroute old or provider schedules into auth maintenance', async () => {
  await env.DB.prepare("INSERT INTO auth_rate_limits(key,count,expiresAt) VALUES('expired-canary',1,0)").run();
  const send = vi.fn().mockResolvedValue(undefined);
  const testEnv = { ...env, OUTBOUND_ENABLED: 'true', JOBS: { send } as unknown as Queue };
  const log = vi.spyOn(console, 'log').mockImplementation(() => {});
  for (const cron of ['17 * * * *', '0 2 * * *'])
    await scheduled({ cron, scheduledTime: Date.now(), noRetry() {} }, testEnv);
  expect(send).toHaveBeenCalledExactlyOnceWith({ type: 'discover' });
  expect(await env.DB.prepare('SELECT count(*) AS n FROM auth_rate_limits').first()).toEqual({ n: 1 });
  expect(log).not.toHaveBeenCalled();
});

it('does not report successful cleanup when the atomic batch fails', async () => {
  const failure = new Error('private-database-error');
  const testEnv = { ...env, DB: { prepare: env.DB.prepare.bind(env.DB), batch: vi.fn().mockRejectedValue(failure) } as unknown as D1Database };
  const log = vi.spyOn(console, 'log').mockImplementation(() => {});
  await expect(cleanupAuth(testEnv)).rejects.toBe(failure);
  expect(log).not.toHaveBeenCalled();
});
