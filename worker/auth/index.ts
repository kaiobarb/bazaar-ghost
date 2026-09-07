import { betterAuth, type BetterAuthOptions } from "better-auth";
import { APIError, createAuthMiddleware, getOAuthState, getSessionFromCtx } from "better-auth/api";
import { atomic } from "../atomic";
import { HttpError, one, rows, statement, uuid } from "../http";
import { availableProviders, providers } from "./providers";
import { clearSessionCookie, configuration, csrf, digest, FRESH_MS, identityCheck, jsonBody, only,
  privateResponse, rateLimit, requireCsrf, requireFresh, requireOrigin, sqlDate, sqlNow, type AuthEnv, type Identity } from "./security";

export { identityCheck, requireCsrf, requireFresh } from "./security";
export type { AuthEnv, Identity } from "./security";

interface Flow { linkUserId: string | null; linkSessionId: string | null }

/** All hook state belongs to ONE invocation; never cache this auth instance globally. */
function createAuth(env: AuthEnv) {
  const { base, origins, secure, secret } = configuration(env);
  const createdUsers = new Set<string>();
  let callbackFlow: Flow | null = null;
  const dropTokens = async () => ({ data: { accessToken: null, refreshToken: null, idToken: null,
    accessTokenExpiresAt: null, refreshTokenExpiresAt: null } });
  const options = {
    database: env.DB, baseURL: base, basePath: "/api/auth", appName: "Bazaarghost", secret,
    trustedOrigins: origins, emailAndPassword: { enabled: false }, telemetry: { enabled: false }, logger: { disabled: true },
    // Isolate-local counters cannot provide an abuse boundary. The HTTP wrapper uses D1.
    rateLimit: { enabled: false },
    user: { modelName: "app_users", additionalFields: {
      status: { type: "string", defaultValue: "active", required: true, input: false, returned: false },
    } },
    session: { modelName: "user_sessions", expiresIn: 604_800, freshAge: 300,
      disableSessionRefresh: true, cookieCache: { enabled: false } },
    account: { modelName: "user_accounts", encryptOAuthTokens: true, storeStateStrategy: "database", storeAccountCookie: false,
      additionalFields: { linkSessionId: { type: "string", required: false, input: false, returned: false } },
      accountLinking: { enabled: true, disableImplicitLinking: true, allowDifferentEmails: true,
        allowUnlinkingAll: false, trustedProviders: ["discord", "twitch"] } },
    verification: { modelName: "auth_verifications" },
    // Better Auth always prepends __Secure- when useSecureCookies=true, even to a
    // custom __Host- name. Own the names instead and set Secure explicitly below.
    advanced: { useSecureCookies: false, cookiePrefix: `${secure ? "__Host-" : ""}bazaarghost`,
      crossSubDomainCookies: { enabled: false },
      cookies: { session_token: { name: `${secure ? "__Host-" : ""}bazaarghost_session` } },
      defaultCookieAttributes: { httpOnly: true, secure, sameSite: "lax", path: "/" },
      ipAddress: { disableIpTracking: true }, database: { generateId: () => crypto.randomUUID() } },
    // Defense in depth: authRoute also allowlists methods and paths and never forwards these.
    disabledPaths: ["/get-session", "/list-sessions", "/list-accounts", "/get-access-token", "/refresh-token",
      "/account-info", "/update-user", "/delete-user", "/change-email", "/unlink-account"],
    socialProviders: providers(env),
    databaseHooks: {
      user: { create: { before: async () => {
        // Better Auth defers create.after until its pseudo-transaction completes, so it
        // never runs when the following account INSERT fails. Allocate and track the
        // server UUID before INSERT; failed inserts simply leave nothing to recover.
        const id = crypto.randomUUID(); createdUsers.add(id);
        return { data: { id, status: "active" } };
      } } },
      account: {
        create: { before: async (account, ctx) => {
          if (!ctx || !callbackFlow) throw new APIError("FORBIDDEN", { message: "Invalid account flow" });
          const state = await getOAuthState();
          if (callbackFlow.linkUserId) {
            if (account.userId !== callbackFlow.linkUserId || state?.link?.userId !== callbackFlow.linkUserId)
              throw new APIError("FORBIDDEN", { message: "Invalid account owner" });
            return { data: { ...(await dropTokens()).data, linkSessionId: callbackFlow.linkSessionId } };
          }
          if (!createdUsers.has(account.userId) || state?.link)
            throw new APIError("FORBIDDEN", { message: "Explicit account linking required" });
          return { data: { ...(await dropTokens()).data, linkSessionId: null } };
        } },
        update: { before: dropTokens },
      },
      session: { create: { before: async (session) => {
        if (!await one(env, `SELECT id FROM app_users u WHERE id=? AND status='active'
          AND EXISTS(SELECT 1 FROM user_accounts a WHERE a.userId=u.id)`, session.userId))
          throw new APIError("FORBIDDEN", { message: "User cannot sign in" });
        return { data: { ipAddress: null, userAgent: null } };
      } } },
    },
    hooks: { before: createAuthMiddleware(async (ctx) => {
      if (!ctx.path.startsWith("/callback/")) return;
      const state: unknown = ctx.query?.state;
      if (typeof state !== "string" || state.length > 256)
        throw new APIError("BAD_REQUEST", { message: "Invalid OAuth state" });
      const cookie = ctx.context.createAuthCookie("state");
      if (await ctx.getSignedCookie(cookie.name, ctx.context.secret) !== state)
        throw new APIError("FORBIDDEN", { message: "Invalid OAuth browser state" });
      // The stock native-D1 flow reads then deletes state in separate queries. This gate is
      // atomic across Workers and also prevents using a Discord state on a Twitch callback.
      const flow = await statement(env, `UPDATE auth_flows SET consumedAt=${sqlNow}
        WHERE stateHash=? AND provider=? AND consumedAt IS NULL AND expiresAt>${sqlNow} RETURNING linkUserId,linkSessionId`,
      await digest(state), ctx.params?.id || ctx.path.slice("/callback/".length)).first<Flow>();
      if (!flow) throw new APIError("FORBIDDEN", { message: "OAuth state expired or already used" });
      if (flow.linkSessionId) {
        const session = await getSessionFromCtx(ctx, { disableCookieCache: true, disableRefresh: true });
        if (!session || session.session.id !== flow.linkSessionId || session.user.id !== flow.linkUserId ||
            Date.now() - new Date(session.session.createdAt).getTime() > FRESH_MS ||
            !await one(env, "SELECT id FROM app_users WHERE id=? AND status='active'", flow.linkUserId))
          throw new APIError("UNAUTHORIZED", { message: "Fresh original linking session required" });
      }
      callbackFlow = flow;
    }) },
  } satisfies BetterAuthOptions;
  const auth = betterAuth(options);
  return { auth, createdUsers };
}

/** Never serialize Better Auth's session object: it contains the bearer session token. */
export async function authenticated(req: Request, env: AuthEnv): Promise<Identity> {
  if (env.AUTH_ENABLED !== "true") throw new HttpError(503, "Authentication disabled");
  const { auth } = createAuth(env);
  const value = await auth.api.getSession({ headers: req.headers, query: { disableCookieCache: true, disableRefresh: true } });
  if (!value) throw new HttpError(401, "Sign in required");
  const exists = await one(env, `SELECT u.id FROM app_users u JOIN user_sessions s ON s.userId=u.id
    WHERE u.id=? AND s.id=? AND u.status='active' AND s.expiresAt>${sqlDate}
    AND EXISTS(SELECT 1 FROM user_accounts a WHERE a.userId=u.id)`, value.user.id, value.session.id);
  if (!exists) throw new HttpError(401, "Sign in required");
  return { userId: value.user.id, sessionId: value.session.id, name: value.user.name, image: value.user.image || null,
    createdAt: value.session.createdAt.toISOString(), expiresAt: value.session.expiresAt.toISOString(),
    csrfToken: await csrf(env, value.user.id, value.session.id) };
}

async function recoverCreatedUsers(env: AuthEnv, ids: Set<string>) {
  if (!ids.size) return;
  // registeredAt is written by the account INSERT trigger, in the SAME statement. A later
  // session failure keeps the valid identity; a failed identity INSERT cannot strand signup.
  await statement(env, `DELETE FROM app_users WHERE id IN(SELECT value FROM json_each(?)) AND registeredAt IS NULL
    AND NOT EXISTS(SELECT 1 FROM user_accounts WHERE userId=app_users.id)
    AND NOT EXISTS(SELECT 1 FROM user_sessions WHERE userId=app_users.id)`, JSON.stringify([...ids])).run();
}

function providerResponse(response: Response, env: AuthEnv) {
  if (response.status >= 300 && response.status < 400 && response.headers.has("Location")) {
    const errorURL = new URL("/api/auth/error", env.PUBLIC_URL);
    const location = new URL(response.headers.get("Location")!, env.PUBLIC_URL);
    if (location.origin === errorURL.origin && location.pathname === errorURL.pathname) {
      // The library places raw provider error/error_description text in redirects.
      // Keep it out of headers, browser history and the next request's URL/logs.
      void response.body?.cancel();
      const sanitized = new Response(null, response);
      sanitized.headers.set("Location", errorURL.href);
      sanitized.headers.delete("Content-Length");
      return sanitized;
    }
  }
  if (response.status < 400) return response;
  // Library/API errors may contain upstream details. The public contract exposes only
  // a restartable failure, never arbitrary provider response text or database errors.
  void response.body?.cancel();
  const headers = new Headers(response.headers);
  headers.delete("Content-Length"); headers.set("Content-Type", "application/json");
  return new Response(JSON.stringify({ error: "Authentication failed; start login again" }), { status: response.status, headers });
}

/** Bounded crash recovery and expired private metadata cleanup; safe to call from cron. */
export async function cleanupAuth(env: AuthEnv) {
  await env.DB.batch([
    ...["auth_flows", "auth_rate_limits", "auth_verifications", "user_sessions"].map(table => statement(env,
      `DELETE FROM ${table} WHERE rowid IN(SELECT rowid FROM ${table} WHERE expiresAt<${table === "auth_flows" || table === "auth_rate_limits" ? sqlNow : sqlDate} ORDER BY expiresAt LIMIT 500)`)),
    statement(env, `DELETE FROM app_users WHERE id IN(SELECT id FROM app_users WHERE registeredAt IS NULL
      AND createdAt<strftime('%Y-%m-%dT%H:%M:%fZ','now','-1 hour') AND NOT EXISTS(SELECT 1 FROM user_accounts WHERE userId=app_users.id)
      AND NOT EXISTS(SELECT 1 FROM user_sessions WHERE userId=app_users.id) ORDER BY createdAt LIMIT 100)`),
  ]);
}

function callbackURL(value: unknown, env: AuthEnv) {
  const { base, origins } = configuration(env);
  if (value === undefined) return base;
  if (typeof value !== "string" || value.length > 2048) throw new HttpError(400, "Invalid callback URL");
  let url: URL;
  try { url = new URL(value, base); } catch { throw new HttpError(400, "Invalid callback URL"); }
  if (!origins.includes(url.origin) || url.username || url.password) throw new HttpError(403, "Untrusted callback URL");
  return url.href;
}

async function dispatch(req: Request, env: AuthEnv): Promise<Response> {
  const path = new URL(req.url).pathname.slice("/api/auth".length);
  if (path === "/providers" && req.method === "GET")
    return Response.json({ enabled: env.AUTH_ENABLED === "true", providers: env.AUTH_ENABLED === "true" ? availableProviders(env) : [] });
  if (path === "/error" && req.method === "GET")
    return Response.json({ error: "Authentication failed; start login again" }, { status: 400 });
  if (env.AUTH_ENABLED !== "true") throw new HttpError(503, "Authentication disabled");
  const get = ["/session", "/accounts", "/sessions"].includes(path) && req.method === "GET";
  const callback = /^\/callback\/(discord|twitch)$/.test(path) && req.method === "GET";
  const post = ["/sign-in/social", "/link-social", "/sign-out", "/sign-out-all", "/unlink-account", "/revoke-session", "/delete-account"].includes(path) && req.method === "POST";
  if (!get && !callback && !post) throw new HttpError(404, "Authentication endpoint not found");
  if (req.url.length > 8192) throw new HttpError(414, "Request URL too long");
  if (post) requireOrigin(req, env);
  await rateLimit(req, env, callback ? "callback" : path === "/sign-in/social" ? "start" : "account", callback ? 30 : path === "/sign-in/social" ? 10 : 120);

  if (callback) {
    if (env.OUTBOUND_ENABLED !== "true") throw new HttpError(503, "External integrations disabled");
    if (!availableProviders(env).includes(path.slice("/callback/".length) as "discord" | "twitch"))
      throw new HttpError(503, "Login provider unavailable");
    const { auth, createdUsers } = createAuth(env);
    try { return providerResponse(await auth.handler(req), env); }
    finally { await recoverCreatedUsers(env, createdUsers); }
  }
  const data = post ? await jsonBody(req) : {};
  if (path === "/sign-in/social" || path === "/link-social") {
    only(data, ["provider", "callbackURL"]);
    if (env.OUTBOUND_ENABLED !== "true") throw new HttpError(503, "External integrations disabled");
    if (!availableProviders(env).includes(data.provider as "discord" | "twitch")) throw new HttpError(400, "Login provider unavailable");
    const identity = path === "/link-social" ? await authenticated(req, env) : null;
    if (identity) { await requireCsrf(req, env, identity); requireFresh(identity); }
    const { auth } = createAuth(env);
    const response = await auth.handler(new Request(req.url, { method: "POST", headers: req.headers,
      body: JSON.stringify({ provider: data.provider, callbackURL: callbackURL(data.callbackURL, env), disableRedirect: true }) }));
    if (!response.ok) return providerResponse(response, env);
    const result = await response.clone().json() as { url?: unknown };
    if (typeof result.url !== "string") throw new HttpError(502, "Unable to start login");
    const state = new URL(result.url).searchParams.get("state");
    if (!state) throw new HttpError(502, "Unable to start login");
    await atomic(env, identity ? [identityCheck(identity, true)] : [], [statement(env,
      `INSERT INTO auth_flows(stateHash,provider,linkUserId,linkSessionId,expiresAt) VALUES(?,?,?,?,?)`,
      await digest(state), data.provider, identity?.userId, identity?.sessionId, Date.now() + 600_000)]);
    return response;
  }
  const identity = await authenticated(req, env);
  if (path === "/session") return Response.json(identity);
  if (path === "/accounts") return Response.json({ accounts: await rows(env,
    "SELECT id,providerId,accountId,createdAt FROM user_accounts WHERE userId=? ORDER BY createdAt,id", identity.userId) });
  if (path === "/sessions") return Response.json({ sessions: await rows(env,
    `SELECT id,createdAt,expiresAt FROM user_sessions WHERE userId=? AND expiresAt>${sqlDate} ORDER BY createdAt,id`, identity.userId) });
  await requireCsrf(req, env, identity);
  only(data, path === "/unlink-account" ? ["accountId"] : path === "/revoke-session" ? ["sessionId"] : []);
  if (path !== "/sign-out") requireFresh(identity);
  const checks = [identityCheck(identity, path !== "/sign-out")];
  const success = () => Response.json({ ok: true });
  if (path === "/unlink-account") {
    const accountId = uuid(data.accountId);
    checks.push({ sql: "EXISTS(SELECT 1 FROM user_accounts WHERE id=? AND userId=?) AND (SELECT count(*) FROM user_accounts WHERE userId=?)>1", args: [accountId, identity.userId, identity.userId] });
    await atomic(env, checks, [statement(env, "DELETE FROM user_accounts WHERE id=? AND userId=?", accountId, identity.userId),
      statement(env, "DELETE FROM user_sessions WHERE userId=? AND id!=?", identity.userId, identity.sessionId)]);
    return success();
  }
  if (path === "/revoke-session") {
    const sessionId = uuid(data.sessionId);
    await atomic(env, checks, [statement(env, "DELETE FROM user_sessions WHERE id=? AND userId=?", sessionId, identity.userId)]);
    return sessionId === identity.sessionId ? clearSessionCookie(env, success()) : success();
  }
  if (path === "/delete-account") {
    await atomic(env, checks, [statement(env, "DELETE FROM app_users WHERE id=?", identity.userId)]);
    return clearSessionCookie(env, success());
  }
  await atomic(env, checks, [statement(env, `DELETE FROM user_sessions WHERE userId=? ${path === "/sign-out" ? "AND id=?" : ""}`,
    identity.userId, ...(path === "/sign-out" ? [identity.sessionId] : []))]);
  return clearSessionCookie(env, success());
}

export async function authRoute(req: Request, env: AuthEnv): Promise<Response> {
  try { return privateResponse(await dispatch(req, env)); }
  catch (error) {
    // Neither OAuth query strings, provider responses, credentials nor database errors are public.
    return privateResponse(Response.json({ error: error instanceof HttpError ? error.message : "Authentication failed" },
      { status: error instanceof HttpError ? error.status : 500 }));
  }
}
