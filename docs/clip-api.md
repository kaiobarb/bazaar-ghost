# Clips, reactions, comments and moderation

This is a backend API. The separate frontend has not been changed. User mutations use the cookie session and CSRF contract in [user-auth.md](user-auth.md); machine processor/catalog credentials cannot act as a user.

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

All user mutations verify the session, trusted Origin, CSRF token, and current database ownership in the same transaction as the write. Reaction, comment and report limits are respectively120,20,5 successful mutations per minute per user. The database stores at most three counters per user. Rejected state conflicts do not consume quota. All social/auth responses are `no-store`.

## Administration

Moderation uses `ADMIN_KEY`, not a user cookie. `GET /api/admin/social/reports` lists open reports (or `status=resolved|dismissed`); `GET /api/admin/social/audit` lists decisions. Both are paginated.

`PUT /api/admin/social/{clips|comments|users|reports}/:id` accepts `{request_id,status,reason}` with a unique client UUID and a substantive reason. Clip/comment statuses are `visible|hidden`; user statuses are `active|suspended`; reports can be `resolved|dismissed`. Repeating the same request acknowledges it without replaying an older moderation decision; changing that request's payload is a conflict. Deleted comment text cannot be restored by moderation. Suspending a user revokes their sessions.

Hidden clips disappear from social reads, legacy/new appearance searches and reviewed groups. Visibility follows the immutable video anchor across OCR replacement. A transactionally incremented cache revision prevents serving an earlier visible search response after moderation. Screenshot delivery requires a currently public detection reference; hidden, orphaned and debug images remain private in R2. Browser responses require revalidation. Already downloaded images or responses cached under older policies cannot be recalled. Operational processing statistics retain raw work counts.

Deleting a user removes their linked identities, sessions, likes, bookmarks, comments and reports. Shared clips and other users' comments remain. Administrative audit entries retain the recorded decision.

## Verification

Local integration tests cover two-user ownership, cookie/CSRF enforcement, reaction idempotency/privacy, comment retries and version conflicts, moderation/suspension, duplicate reports, account deletion, and actual processor clear/upload/publish cycles preserving social records. Hosted provider authentication still needs real configuration/consent; that requirement cannot be replaced by mocked OAuth or manually seeded test sessions.
