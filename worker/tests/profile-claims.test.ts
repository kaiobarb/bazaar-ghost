import { env, SELF } from 'cloudflare:test';
import { beforeEach, expect, it } from 'vitest';
import { setProfile } from '../admin';
import { one, statement } from '../http';
import { plan } from '../processing';

const profile = () => ({ id: 1, crop_region: [0, 0, 1, 1], igd_crop_region: [0, 0, 0.1, 0.1],
  custom_edge: 0.8, opaque_edge: true });
const expected = () => ({ expected_profile: profile(), expected_old_templates: false });
let chunkId: string;
beforeEach(async () => {
  await statement(env, `INSERT INTO sfde_profiles(id,profile_name,crop_region,igd_crop_region,custom_edge,opaque_edge)
    VALUES(1,'reviewed','[0.0, 0.0, 1.0, 1.0]','[0.0, 0.0, 0.1, 0.1]',0.8,1)`).run();
  await statement(env, "INSERT INTO streamers(id,login) VALUES(1,'reviewed')").run();
  await statement(env, `INSERT INTO vods(id,streamer_id,source_id,duration_seconds,published_at,bazaar_chapters,ready_for_processing)
    VALUES(1,1,'123',100,'2026-09-07T00:00:00Z','[0,100]',1)`).run();
  chunkId = (await plan(env, 1))[0].id;
});
const state = () => one(env, 'SELECT status,attempt_count,claim_token,lease_expires_at FROM chunks WHERE id=?', chunkId);
function request(data: unknown) {
  return SELF.fetch(`http://local/api/processor/chunks/${chunkId}/claim`, {
    method: 'POST', headers: { Authorization: `Bearer ${env.PROCESSOR_KEY}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
}

it('requires complete typed profile and template expectations at the HTTP boundary', async () => {
  const before = await state();
  for (const payload of [
    {}, { expected_profile: profile() }, { expected_old_templates: false },
    { ...expected(), expected_profile: null }, { ...expected(), expected_profile: [] },
    { ...expected(), expected_old_templates: null }, { ...expected(), expected_old_templates: 'false' },
    ...[{ id: true }, { id: '1' }, { crop_region: [0, 0, 1] }, { crop_region: [false, 0, 1, 1] },
      { igd_crop_region: 'null' }, { custom_edge: '0.8' }, { opaque_edge: 1 }, { opaque_edge: undefined }]
      .map(change => ({ ...expected(), expected_profile: { ...profile(), ...change } })),
  ]) {
    expect((await request(payload)).status).toBe(400);
    expect(await state()).toEqual(before);
  }
});

it('accepts normalized numeric profile values and ignores unrelated metadata without rewriting the saved profile', async () => {
  const before = await one(env, 'SELECT * FROM sfde_profiles WHERE id=1');
  const response = await request({ ...expected(), expected_profile: { ...profile(), profile_name: 'old label', updated_at: 'old timestamp' } });
  expect(response.status).toBe(200);
  const result = await response.json<{ claimed: boolean; claim_token: string }>();
  expect(result.claimed).toBe(true);
  expect(result.claim_token).toMatch(/^[a-f0-9-]{36}$/);
  expect(await state()).toMatchObject({ status: 'processing', attempt_count: 1, claim_token: result.claim_token });
  expect(await one(env, 'SELECT * FROM sfde_profiles WHERE id=1')).toEqual(before);
});

it('rejects stale processing values before taking ownership or clearing a prior detection', async () => {
  await statement(env, "INSERT INTO search_names(name,gram_count) VALUES('prior',0)").run();
  await statement(env, `INSERT INTO detections(id,chunk_id,vod_id,username,username_lower,confidence,frame_time_seconds)
    VALUES('prior',?,1,'Prior','prior',0.9,12)`, chunkId).run();
  const before = await state();
  for (const payload of [
    { ...expected(), expected_old_templates: true },
    ...[{ id: 2 }, { crop_region: [0.1, 0, 0.9, 1] }, { igd_crop_region: null },
      { custom_edge: null }, { opaque_edge: false }]
      .map(change => ({ ...expected(), expected_profile: { ...profile(), ...change } })),
  ]) {
    const response = await request(payload);
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ claimed: false, claim_token: null });
    expect(await state()).toEqual(before);
    expect(await one(env, "SELECT username FROM detections WHERE id='prior'")).toEqual({ username: 'Prior' });
  }
});

it('accepts absent optional crop and edge only when the saved profile also has NULL values', async () => {
  await setProfile(env, { ...profile(), profile_name: 'reviewed', igd_crop_region: null, custom_edge: null });
  const response = await request({ expected_profile: { id: 1, crop_region: [0, 0, 1, 1], opaque_edge: true }, expected_old_templates: false });
  expect(response.status).toBe(200);
  expect(await response.json()).toMatchObject({ claimed: true });
});

it('keeps queue timestamp ownership independent of a matching profile', async () => {
  const queuedAt = '2026-09-07T00:00:00.000Z';
  await statement(env, "UPDATE chunks SET status='queued',queued_at=? WHERE id=?", queuedAt, chunkId).run();
  const before = await state();
  const stale = await request({ ...expected(), queued_at: '2026-09-06T00:00:00.000Z' });
  expect(await stale.json()).toEqual({ claimed: false, claim_token: null });
  expect(await state()).toEqual(before);
  const current = await request({ ...expected(), queued_at: queuedAt });
  expect(await current.json()).toMatchObject({ claimed: true });
});
