# User authentication

Status: deployed to the dedicated validation Worker at `1c5428c`, with hosted session/social checks in progress. Existing dev/production remain unchanged. Real provider login requires dedicated OAuth application configuration and user consent; mocked provider tests do not establish hosted login success.

The Worker runs Better Auth with native D1 storage. The public surface is explicitly limited to `/api/auth/*`. Application sessions use an HTTP-only, Secure, host-only cookie on HTTPS (`__Host-bazaarghost_session`), with SameSite=Lax and a seven-day expiry. The browser sends `credentials: 'include'`; it never receives an admin, catalog, or processor key. Session responses contain application identity and a session-bound CSRF token, not the bearer session token or email.

Discord login requests `identify`, without email, bot installation, guild access, or messages. Twitch login validates the access token's client and user identity with Twitch and reads the corresponding Helix user. Provider access/refresh/ID tokens are discarded after identity verification. Synthetic internal addresses satisfy the library schema; the application does not collect an email address or send email.

## Dedicated validation setup

Use separate test OAuth applications. Keep existing production/dev callback registrations intact.

| Provider | Exact registered redirect URI | Worker secrets |
|---|---|---|
| Discord | `https://bazaarghost-validation.kaio-8df.workers.dev/api/auth/callback/discord` | `DISCORD_AUTH_CLIENT_ID`, `DISCORD_AUTH_CLIENT_SECRET` |
| Twitch | `https://bazaarghost-validation.kaio-8df.workers.dev/api/auth/callback/twitch` | `TWITCH_AUTH_CLIENT_ID`, `TWITCH_AUTH_CLIENT_SECRET` |

Set these secrets on **bazaarghost-validation** using the Cloudflare dashboard or `npx wrangler secret put <NAME> --config wrangler.validation.jsonc` from this worktree. Do not paste secrets into chat or commit them. `AUTH_SECRET` is an independent randomly generated value of at least 32 characters for the environment. These credentials are distinct from the Discord bot and Twitch catalog credentials.

`AUTH_ENABLED` defaults to false for local/dev/production and is enabled in the dedicated validation configuration. Provider calls additionally require `OUTBOUND_ENABLED=true` and actual provider credentials; an enabled module with no configured providers cannot initiate login. Enabling login does not itself create ingestion schedules. `PUBLIC_URL` must be the exact backend origin, and trusted browser origins come from it plus `CORS_ORIGINS`. Hosted origins require HTTPS. The validation config currently trusts only its own HTTPS origin. A future separate browser frontend must use an explicitly reviewed origin and cookie-compatible deployment; cross-site third-party-cookie restrictions are not solved by CORS alone.

OAuth state is bound to its original browser, provider, and, for linking, its original fresh session. A separate D1 record atomically consumes each state before provider calls. Application database constraints check account/session consistency and revocation during native D1 writes. Failed registration recovery removes only identities created by that failed attempt that never acquired an account or session.

## Browser-facing API

| Method and route under `/api/auth` | Contract |
|---|---|
| `GET /providers` | Enabled state and configured provider names |
| `POST /sign-in/social` | JSON `{provider, callbackURL?}`; returns authorization URL and sets browser state cookie |
| `GET /callback/discord`, `/callback/twitch` | Provider redirect only; verifies/consumes state, creates session, redirects to the allowed callback URL |
| `GET /session` | Safe user/session identity and `csrfToken`; rejects absent, expired, or revoked sessions |
| `GET /accounts` | The signed-in user's linked identities |
| `GET /sessions` | The signed-in user's live sessions, excluding bearer tokens |
| `POST /link-social` | Explicitly link another provider to the current account; fresh login and CSRF required |
| `POST /unlink-account` | `{accountId}` for the caller's linked-account record; cannot remove the final identity; revokes other sessions |
| `POST /revoke-session` | `{sessionId}` for the caller's session |
| `POST /sign-out` | Revoke the current session and clear its cookie |
| `POST /sign-out-all` | Revoke all caller sessions and clear the current cookie |
| `POST /delete-account` | Remove caller identity, linked accounts, sessions, and owned social records through cascades |

All POSTs require JSON and an exact trusted `Origin`. Signed-in mutations additionally require `X-CSRF-Token` from `/session`. Linking, unlinking, deletion, revoking sessions, and signing out all sessions require a login from the last five minutes. Ordinary sign-out remains available for an older valid session. Implicit account merging by email is disabled. OAuth/account endpoints and errors are not cached.

Authentication request limits use bounded, expiring D1 counters keyed by a secret-derived IP hash; raw IPs are not persisted. The hourly `17 * * * *` Cron runs bounded cleanup of expired auth state, sessions, and crash-orphaned registrations, including while outbound integrations are disabled. OAuth failures at `/api/auth/error` have a generic response; upstream error descriptions are removed from that redirect URL.

Hosted acceptance still requires real Discord/Twitch consent flows, repeat login, explicit linking, account collision rejection, session revocation, CSRF enforcement, and account deletion against the isolated Worker. Tests must not add a deployed fake-login endpoint to make those checks pass.
