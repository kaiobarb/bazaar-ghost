import { env } from 'cloudflare:test';
import { expect, it } from 'vitest';
import { cleanupAuth } from '../auth';

const metadata = [
  ['auth_flows', 'stateHash'],
  ['auth_rate_limits', 'key'],
  ['auth_verifications', 'id'],
  ['user_sessions', 'id'],
] as const;

async function registeredUser(id: string, createdAt: string, removeAccount = false) {
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO app_users(id,name,email,emailVerified,createdAt,updatedAt)
      VALUES(?,?,?,0,?,?)`).bind(id, id, `${id}@cleanup.test.invalid`, createdAt, createdAt),
    env.DB.prepare(`INSERT INTO user_accounts(id,accountId,providerId,userId,createdAt,updatedAt)
      VALUES(?,?,'discord',?,?,?)`).bind(`${id}-account`, `${id}-subject`, id, createdAt, createdAt),
    ...(removeAccount ? [env.DB.prepare('DELETE FROM user_accounts WHERE userId=?').bind(id)] : []),
  ]);
}

it('deletes the oldest 500 expired rows per metadata table, preserving live rows and draining the remainder on the next pass', async () => {
  const time = Date.now(), created = new Date(time - 7_200_000).toISOString();
  await registeredUser('metadata-owner', created);
  const input = JSON.stringify(Array.from({ length: 501 }, (_, index) => ({
    id: `expired-${String(index).padStart(3, '0')}`,
    ms: time - 60_000 + index,
    iso: new Date(time - 60_000 + index).toISOString(),
  })));
  const future = time + 3_600_000, futureISO = new Date(future).toISOString();
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO auth_flows(stateHash,provider,expiresAt)
      SELECT json_extract(value,'$.id'),'discord',json_extract(value,'$.ms') FROM json_each(?)`).bind(input),
    env.DB.prepare(`INSERT INTO auth_rate_limits(key,count,expiresAt)
      SELECT json_extract(value,'$.id'),3,json_extract(value,'$.ms') FROM json_each(?)`).bind(input),
    env.DB.prepare(`INSERT INTO auth_verifications(id,identifier,value,expiresAt,createdAt,updatedAt)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.id'),'fixture-state',json_extract(value,'$.iso'),?,?
      FROM json_each(?)`).bind(created, created, input),
    env.DB.prepare(`INSERT INTO user_sessions(id,token,userId,expiresAt,createdAt,updatedAt)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.id'),'metadata-owner',json_extract(value,'$.iso'),?,?
      FROM json_each(?)`).bind(created, created, input),
    env.DB.prepare(`INSERT INTO auth_flows(stateHash,provider,expiresAt,consumedAt)
      VALUES('live-flow','discord',?,NULL),('live-consumed-flow','twitch',?,?)`).bind(future, future, time - 1_000),
    env.DB.prepare(`INSERT INTO auth_rate_limits(key,count,expiresAt) VALUES('live-rate',7,?)`).bind(future),
    env.DB.prepare(`INSERT INTO auth_verifications(id,identifier,value,expiresAt,createdAt,updatedAt)
      VALUES('live-verification','live-verification','live-state',?,?,?)`).bind(futureISO, created, created),
    env.DB.prepare(`INSERT INTO user_sessions(id,token,userId,expiresAt,createdAt,updatedAt)
      VALUES('live-session','live-session-token','metadata-owner',?,?,?)`).bind(futureISO, created, created),
  ]);

  const liveRows = await Promise.all(metadata.map(([table, id]) =>
    env.DB.prepare(`SELECT * FROM ${table} WHERE ${id} LIKE 'live-%' ORDER BY ${id}`).all()));
  const owner = await env.DB.prepare("SELECT * FROM app_users WHERE id='metadata-owner'").first();
  const account = await env.DB.prepare("SELECT * FROM user_accounts WHERE userId='metadata-owner'").first();
  expect(owner!.registeredAt).toBeGreaterThan(0);

  for (const [table, id] of metadata) {
    expect(await env.DB.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${id} LIKE 'expired-%'`).first()).toEqual({ n: 501 });
  }
  await cleanupAuth(env);
  for (const [index, [table, id]] of metadata.entries()) {
    expect((await env.DB.prepare(`SELECT ${id} AS id FROM ${table} WHERE ${id} LIKE 'expired-%'`).all()).results)
      .toEqual([{ id: 'expired-500' }]);
    expect((await env.DB.prepare(`SELECT * FROM ${table} WHERE ${id} LIKE 'live-%' ORDER BY ${id}`).all()).results)
      .toEqual(liveRows[index].results);
  }

  await cleanupAuth(env);
  for (const [index, [table, id]] of metadata.entries()) {
    expect(await env.DB.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${id} LIKE 'expired-%'`).first()).toEqual({ n: 0 });
    expect((await env.DB.prepare(`SELECT * FROM ${table} ORDER BY ${id}`).all()).results).toEqual(liveRows[index].results);
  }
  expect(await env.DB.prepare("SELECT * FROM app_users WHERE id='metadata-owner'").first()).toEqual(owner);
  expect(await env.DB.prepare("SELECT * FROM user_accounts WHERE userId='metadata-owner'").first()).toEqual(account);
  expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
});

it('deletes at most 100 aged abandoned users per pass without deleting fresh or previously registered accountless users', async () => {
  const time = Date.now(), created = new Date(time - 7_200_000).toISOString();
  await registeredUser('registered-accountless', created, true);
  const abandoned = JSON.stringify(Array.from({ length: 101 }, (_, index) => ({
    id: `orphan-${String(index).padStart(3, '0')}`,
    created: new Date(time - 7_200_000 + index).toISOString(),
  })));
  await env.DB.batch([
    env.DB.prepare(`INSERT INTO app_users(id,name,email,emailVerified,createdAt,updatedAt)
      SELECT json_extract(value,'$.id'),json_extract(value,'$.id'),json_extract(value,'$.id')||'@cleanup.test.invalid',0,
        json_extract(value,'$.created'),json_extract(value,'$.created') FROM json_each(?)`).bind(abandoned),
    env.DB.prepare(`INSERT INTO app_users(id,name,email,emailVerified,createdAt,updatedAt)
      VALUES('fresh-orphan','fresh-orphan','fresh-orphan@cleanup.test.invalid',0,?,?)`)
      .bind(new Date(time).toISOString(), new Date(time).toISOString()),
  ]);
  const survivors = (await env.DB.prepare("SELECT * FROM app_users WHERE id IN('fresh-orphan','registered-accountless') ORDER BY id").all()).results;
  expect(survivors.find(user => user.id === 'registered-accountless')!.registeredAt).toBeGreaterThan(0);
  expect(survivors.find(user => user.id === 'fresh-orphan')!.registeredAt).toBeNull();
  expect(await env.DB.prepare('SELECT count(*) AS n FROM user_accounts').first()).toEqual({ n: 0 });
  expect(await env.DB.prepare('SELECT count(*) AS n FROM user_sessions').first()).toEqual({ n: 0 });

  await cleanupAuth(env);
  expect((await env.DB.prepare("SELECT id FROM app_users WHERE id LIKE 'orphan-%'").all()).results)
    .toEqual([{ id: 'orphan-100' }]);
  expect((await env.DB.prepare("SELECT * FROM app_users WHERE id IN('fresh-orphan','registered-accountless') ORDER BY id").all()).results)
    .toEqual(survivors);

  await cleanupAuth(env);
  expect((await env.DB.prepare('SELECT * FROM app_users ORDER BY id').all()).results).toEqual(survivors);
  expect((await env.DB.prepare('PRAGMA foreign_key_check').all()).results).toEqual([]);
});
