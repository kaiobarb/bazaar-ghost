# Clips, reactions, comments and moderation

This backend API is deployed on the dedicated validation Worker at `3d00e92`; hosted HTTP mechanics and synthetic processor reprocessing passed on September 7, 2026 (local time). The separate frontend has not been changed. User mutations use the cookie session and CSRF contract in [user-auth.md](user-auth.md); machine processor/catalog credentials cannot act as a user. Real provider login remains pending configuration and browser consent.

A clip is a persistent `(vod_id, anchor_seconds)` with its own integer ID. It points to the current qualifying OCR detection at that exact video timestamp. Database migration backfills existing detections, and new publications create/reconnect clips automatically. Clearing or replacing OCR results keeps the clip ID, likes, favorites, and comments. A nearby timestamp does not automatically inherit someone else's discussion. Removing the entire video deletes its clips; marking a recording unavailable preserves the anchor, with no currently public detection attached to its response.

## Public and signed-in routes

| Method and route | Behavior |
|---|---|
| `GET /api/v1/clips` | Paginated clips; optional `source`, internal `vod_id`, or `detection_id` filters |
| `POST /api/v1/clips` | Signed-in `{detection_id}` resolves/materializes a visible clip idempotently |
| `GET /api/v1/clips/:id` | Source, anchor, optional current detection and public like count |
| `GET /api/v1/clips/:id/me` | Only the caller's `{liked,favorite}` state |
| `PUT /api/v1/clips/:id/like` | Ensure caller likes this clip; empty body |
| `DELETE /api/v1/clips/:id/like` | Ensure caller does not like it; empty body |
| `PUT /api/v1/clips/:id/favorite` | Ensure caller has privately bookmarked it; empty body |
| `DELETE /api/v1/clips/:id/favorite` | Remove caller's bookmark; empty body |
| `GET /api/v1/me/favorites` | Caller-only paginated saved clips |
| `GET /api/v1/clips/:id/comments` | Paginated visible comments from active users |
| `POST /api/v1/clips/:id/comments` | `{id,body}`, where `id` is a client-generated UUID for retry identity |
| `GET /api/v1/comments/:id` | One visible comment |
| `PATCH /api/v1/comments/:id` | Author-only `{version,body}`; rejects a stale version |
| `DELETE /api/v1/comments/:id` | Author-only `{version}`; retains a retry tombstone without comment text |
| `POST /api/v1/reports` | `{id,reason,clip_id}` or `{id,reason,comment_id}`; one report per caller/target |
| `GET /api/v1/me` | Alias for safe current identity/session/CSRF output |

`heart` is an alias for `favorite`, backed by the same private bookmark. It is separate from a like. There is no public favorite count or list of bookmark owners. Public like counts exclude suspended users. Lists return `{items,next_after}` and accept `limit` (1–50, default25) and the returned `after` cursor.

Comments are plain text, normalized to NFC, with 1–2000 Unicode characters. Invisible/control-only text is rejected. Clients must render the body as text rather than HTML. Public authors expose only the application user ID and display name. The original request hash prevents retrying a comment UUID with a different body or target. A retry after editing/deleting cannot restore the original text. Concurrent edits use the supplied version instead of silently overwriting one another.

Each user mutation verifies the cookie, exact trusted Origin, and session-bound CSRF token. Its database transaction rechecks the live session, active user, target visibility where required, and ownership together with the write. Reaction, comment and report limits are respectively 120, 20, and 5 successful requests per minute per user, including accepted idempotent retries. The database stores at most three counters per user. Rejected state conflicts do not consume quota. All social/auth responses are `no-store`.

## Administration

Moderation uses `ADMIN_KEY`, not a user cookie. `GET /api/admin/social/reports` lists open reports (or `status=resolved|dismissed`); `GET /api/admin/social/audit` lists decisions. Both are paginated.

`PUT /api/admin/social/{clips|comments|users|reports}/:id` accepts `{request_id,status,reason}` with a unique client UUID and a substantive reason. Clip/comment statuses are `visible|hidden`; user statuses are `active|suspended`; reports can be `resolved|dismissed`. Repeating the same request acknowledges it without replaying an older moderation decision; changing that request's payload is a conflict. Deleted comment text cannot be restored by moderation. Suspending a user revokes their sessions.

Hidden clips disappear from social reads, legacy/new appearance searches and reviewed groups. Visibility follows the immutable video anchor across OCR replacement. A transactionally incremented cache revision prevents serving an earlier visible search response after moderation. Screenshot delivery requires a currently public detection reference; hidden, orphaned and debug images remain private in R2. Browser responses require revalidation. Already downloaded images or responses cached under older policies cannot be recalled. Operational processing statistics retain raw work counts.

Deleting a user removes their linked identities, sessions, likes, bookmarks, comments and reports. Shared clips and other users' comments remain. Administrative audit entries retain the recorded decision.

## Verification

The hosted mechanics smoke passed on exact validation build `1c5428c68ca035bab24b43fef1a34820435a8608` on 2026-09-07. Two temporary operator-created users used actual signed session cookies over HTTP. Checks covered unique public likes, private favorites and the heart alias, bookmark removal, anonymous/cross-user privacy rejection, comment ownership, stale-version conflicts, idempotent creation/deletion, retry tombstones, report creation, CSRF/CORS, session revocation, and account-deletion cascades.

Existing Bilibili clip `1` was briefly hidden and restored through the admin API. Previously requested public view/search/appearance URLs excluded the hidden detection, and screenshot GET/HEAD requests with and without ETag returned 404. Restoration returned the original 4,646-byte screenshot with SHA-256 `03bf3eb0d204ec959993845f0ba2adf7c620a7f67ef75555890386bba2aaac38`. The original clip/detection identity and all seventeen real clips/detections remained intact. Cleanup verified zero synthetic users, accounts, sessions, or owned social records; two admin audit entries remain as the actual moderation trail.

Private local evidence: `.ignore/platform-validation/hosted-social-smoke.6dfcb900-8bb2-4c85-8f5f-7c8e29409973/proof.json`. This validates hosted API mechanics with operator fixtures, not real OAuth consent or a browser frontend. The provider/browser acceptance work is specified in [user-auth.md](user-auth.md#verification-and-remaining-acceptance).

An expanded hosted proof passed on the same build from 18:27:03 to 18:28:16 UTC. Racing same-version comment edits produced one success and one conflict. Comment hide/restore and report resolve/dismiss cycles rejected stale decision replay; concurrent resolution created one decision. Suspension immediately revoked the cookie, excluded the user's likes, and hid comments; reactivation restored contributions without reviving the revoked session. Deleting a second user preserved the first user's comment and the shared clip.

The expanded proof sent 121 actual reaction requests within one database minute, with at most eight in flight: 120 succeeded, one returned 429, the quota counter was 120, and one unique like existed. Cleanup removed every fixture-owned row and preserved all 43 original clip/detection IDs. Six fixture moderation audit decisions remain. Evidence: `.ignore/platform-validation/hosted-social-expanded.b6e1dabe-9a75-4ecc-8f58-3841f0355cbf/proof.json`.

The hosted reprocessing proof passed on `3d00e92` from `2026-09-08T00:14:32.849Z` to `00:15:19.811Z`. A disposable recording used the actual processor claim/upload/publish/completion routes and shared admin retry endpoint. At timestamp 12, clearing and replacing OCR retained the same clip ID, like, private favorite, and comment. Publishing timestamp 13 first did not transfer those records. Hidden status at 12 survived another complete retry/republication. Warmed searches and screenshot GET/HEAD/ETag requests denied the hidden frame within 1,338 ms, before the 30-second internal cache could expire; a physical R2 read verified its stored bytes independently.

Cleanup removed all five uploaded fixture JPEGs and verified six tracked keys absent, including one never-created access probe. All fixture-owned database rows were absent, foreign keys were clean, and full-row hashes of all 43 original clips and detections were unchanged. A separate D1 query confirmed cleanup and the one genuine moderation audit intentionally retained. Evidence: `.ignore/platform-validation/hosted-reprocess-smoke.f5cd8059-2c6d-434f-b379-5ca162e4556f/{proof.json,independent-cleanup-proof.json}`. This is synthetic processor/API evidence, not another real-media OCR run or provider login.

Local integration tests additionally cover pagination and revocation/moderation races. The remaining bounded hosted checks are favorite/comment pagination across visible and hidden rows, and quota recovery in the next database time window, using disposable fixtures.
