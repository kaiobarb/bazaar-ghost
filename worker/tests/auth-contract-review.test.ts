import { env } from 'cloudflare:test';
import { afterEach, beforeEach, expect, it, vi } from 'vitest';
import { authRoute } from '../auth';
import { authEnv, complete, cookies, login, mockProviders, ORIGIN, request, start } from './auth-fixture';

beforeEach(async()=>{
  await env.DB.batch(['auth_flows','auth_rate_limits','auth_verifications','user_sessions','user_accounts','app_users'].map(table=>env.DB.prepare(`DELETE FROM ${table}`)));
  mockProviders();
});
afterEach(()=>vi.unstubAllGlobals());

it('does not reflect provider error descriptions in redirect headers or the next request URL',async()=>{
  const flow=await start();
  const response=await authRoute(request(`/callback/discord?state=${encodeURIComponent(flow.url.searchParams.get('state')!)}&error=access_denied&error_description=provider-private-detail`,undefined,flow.cookie),authEnv());
  expect(response.status).toBe(302);
  expect(response.headers.get('location')).toBe(ORIGIN+'/api/auth/error');
  expect(await response.text()).not.toContain('provider-private-detail');
  expect((await complete(flow)).status).toBe(403);
});

it('preserves a successful trusted callback URL, including application-owned query parameters',async()=>{
  const callbackURL=ORIGIN+'/done?error_description=application-owned-value';
  const started=await authRoute(request('/sign-in/social',{provider:'discord',callbackURL}),authEnv());
  const result=await started.json() as {url:string};
  const response=await complete({url:new URL(result.url),cookie:cookies(started)});
  expect(response.headers.get('location')).toBe(callbackURL);
  expect(response.headers.get('cache-control')).toBe('no-store');
  expect(response.headers.getSetCookie().some(value=>value.startsWith('__Host-bazaarghost_session='))).toBe(true);
});

it('uses exact host-bound names for HTTPS session and OAuth state cookies and clears the actual session cookie',async()=>{
  const flow=await start();
  expect(flow.cookie.split(';').some(value=>value.trim().startsWith('__Host-bazaarghost.state='))).toBe(true);
  expect(flow.cookie).not.toContain('__Secure-__Host-');
  const user=await login();
  const sessionCookie=user.response.headers.getSetCookie().find(value=>value.startsWith('__Host-bazaarghost_session='))!;
  expect(sessionCookie).toBeTruthy();
  expect(sessionCookie).toContain('Secure');
  expect(sessionCookie).toContain('HttpOnly');
  expect(sessionCookie).toContain('Path=/');
  expect(sessionCookie).not.toContain('Domain=');
  const response=await authRoute(request('/sign-out',{},user.cookie,user.identity.csrfToken),authEnv());
  expect(response.status).toBe(200);
  expect(response.headers.getSetCookie().some(value=>value.startsWith('__Host-bazaarghost_session=;')&&value.includes('Max-Age=0'))).toBe(true);
});

it('keeps HTTP localhost cookie names unprefixed while preserving browser-bound OAuth state',async()=>{
  const local={...authEnv(),ENVIRONMENT:'local',PUBLIC_URL:'http://localhost:8787',CORS_ORIGINS:'http://localhost:8787'};
  const response=await authRoute(new Request('http://localhost:8787/api/auth/sign-in/social',{
    method:'POST',headers:{Origin:local.PUBLIC_URL,'Content-Type':'application/json'},
    body:JSON.stringify({provider:'discord'}),
  }),local);
  expect(response.status).toBe(200);
  const state=response.headers.getSetCookie().find(value=>value.startsWith('bazaarghost.state='))!;
  expect(state).toBeTruthy();
  expect(state).toContain('HttpOnly');
  expect(state).not.toContain('Secure');
});

it('does not strand or replace a provider identity when two first sign-ins race',async()=>{
  const flows=await Promise.all([start(),start()]);
  const responses=await Promise.all(flows.map(flow=>complete(flow)));
  expect(responses.some(response=>response.headers.get('location')===ORIGIN+'/done')).toBe(true);
  expect((await env.DB.prepare('SELECT count(*) count FROM app_users').first())!.count).toBe(1);
  expect((await env.DB.prepare('SELECT count(*) count FROM user_accounts').first())!.count).toBe(1);
  const retry=await complete(await start());
  expect(retry.headers.get('location')).toBe(ORIGIN+'/done');
});
