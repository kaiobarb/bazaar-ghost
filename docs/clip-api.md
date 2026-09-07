# Clips, reactions, comments and moderation

This backend API is deployed on the dedicated validation Worker at `1c5428c`; hosted HTTP mechanics passed on 2026-09-07. The separate frontend has not been changed. User mutations use the cookie session and CSRF contract in [user-auth.md](user-auth.md); machine processor/catalog credentials cannot act as a user. Real provider login remains pending configuration and browser consent.

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

Local integration tests also cover moderation/suspension, report deduplication/resolution, pagination, quota boundaries, revocation/moderation races, simultaneous retries, and actual processor clear/upload/publish cycles preserving social records. Those additional branches have not all been repeated against the hosted Worker. The next bounded hosted checks should use disposable fixtures:

- Run a comment/report moderation cycle: hide and restore a comment, reject an author edit while hidden, resolve its report, and verify that retrying an old decision does not overwrite the newer decision or duplicate its audit entry.
- Suspend a fixture user and verify immediate session revocation, hidden comments, excluded likes, and restoration of public contributions without revival of old cookies. Confirm that deleting one user preserves a second user's comment and the shared clip.
- Exercise quota boundaries and concurrent retries: a duplicate comment produces one row, competing edits produce one successful version change, a rejected quota request makes no data change, and the next time window permits another request. Check favorite/comment pagination across visible and hidden rows.
- Process and then reprocess a disposable validation recording through the existing processor API. The exact anchor must keep its clip ID, comments, likes, and favorites; a replacement at an adjacent timestamp must not inherit them. Repeat with a hidden anchor and confirm that public search and screenshot access stay hidden. The successful smoke above deliberately did not clear or reprocess the existing real clip.
