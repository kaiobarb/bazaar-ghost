# Backend validation status

This is the acceptance record for the dedicated Cloudflare migration environment, not a production cutover checklist marked complete. Detailed chronology is in [platform-work-log.md](platform-work-log.md).

## Environment and execution

- Branch: `codex/cloudflare-validation`; existing `dev`, `main`, and the separate frontend remain untouched.
- Hosted Worker: `bazaarghost-validation`, at `https://bazaarghost-validation.kaio-8df.workers.dev`.
- Verified deployed application: `3d00e92bbf0e5f7058eef8e5627ce67303947765`; Worker version `cf381092-3bf5-4249-8ec9-7db69143d99f`; migrations `0001`–`0006` applied.
- D1, both R2 buckets, the queue, and dead-letter queue belong to validation. Auth is enabled; outbound integrations are disabled. The provider endpoint reports no configured login providers. Auth maintenance at `17 * * * *` is the only configured Cron.
- OCR and workflow execution stay in GitHub Actions. Successful YouTube jobs used disposable, one-job local-container Actions runners. Those runners and containers were removed afterward.
- [CI 34171462120](https://github.com/liftaris/bazaar-ghost/actions/runs/34171462120) passed, including 173 Worker tests. Its deployment steps were skipped. The application was subsequently deployed through authenticated local Wrangler and independently checked over HTTP; CI success alone is not deployment evidence.

## Capability acceptance

| Capability | Established evidence | Remaining acceptance |
|---|---|---|
| Multiplatform catalog and processing contracts | Twitch/YouTube/Bilibili source identity, account/profile controls, chunk ownership, lease fencing, and retry eligibility have local runtime tests. Actual Bilibili and YouTube recordings persisted through the hosted API. | A complete real Twitch recording on this validation backend. |
| Full recording coverage | Three source uploads completed every expected sampled timestamp; terminal database state, published detections, and decodable screenshot bytes agree with Actions artifacts. See recording table below. | This establishes sampled coverage, not exhaustive matchup recall or perfect OCR labels. |
| In-game day extraction (IGD) | The two full YouTube runs persisted 23 non-null readings. Reviewed local windows produced ten correct accepted days and one deliberately null low-confidence result. Selected hosted days were visually checked. | All 23 hosted values have not been visually certified. Bilibili's completed runs had IGD disabled. |
| Duplicate appearances | Thirteen visually reviewed fights each group one YouTube and one Bilibili appearance. Both source-filtered hosted searches returned all thirteen groups and 26 appearances. | General automatic duplicate detection is not established by manually reviewed grouping. |
| Reprocessing | Eight new runtime regressions cover source-specific eligibility, preservation of completed siblings, and competing writes. A hosted disposable recording exercised actual claim/complete/admin retry/clear/upload/publish: the exact anchor retained its clip ID and social records, an adjacent anchor inherited none, and hidden status survived another publication. Physical R2 reads confirmed replacement bytes and object removal. | This is synthetic processor/API evidence, separate from the real-media OCR runs below. |
| User sessions | Hosted signed-cookie fixtures verify identity, CSRF, CORS, ownership, revocation, deletion, and suspension. Local D1 tests cover mocked OAuth callbacks, state binding/replay, linking, and races. | Real Discord/Twitch consent and linking, browser cookie behavior, actual application origin, and hosted expiry-maintenance acceptance. |
| Likes, favorites, comments, moderation | Hosted HTTP checks verify unique likes, private favorite/heart alias, comment ownership/versioning/retry tombstones, moderation replay safety, reporting, suspension, and deletion cascades. | Hosted pagination across hidden rows and recovery in the next quota window. |
| Abuse limits | A hosted test made 121 actual reaction requests in one database minute: 120 accepted, one rejected with 429, persisted counter 120, one unique like. | Next-window recovery remains separate from proving the limit. |
| Public search and screenshots | Hosted source/group reads agree with persisted detections. Moderation removed a real clip from warmed reads and denied screenshot GET/HEAD, including ETag requests; restoring it returned identical image bytes. The synthetic retry proof also preserved hidden status through republication and rechecked warmed search/image denial in 1,338 ms, within the 30-second cache lifetime. | Downloaded bytes cannot be recalled. These checks do not establish exhaustive visual/OCR accuracy. |
| Automatic ingestion | YouTube account polling queued forty candidates. Bilibili feed failures and YouTube runner authentication failures persisted finite diagnostics and released their leases. | A healthy automatic catalog-to-dispatch-to-completion cycle. Bilibili feeds currently reject access; GitHub-hosted YouTube extraction requests sign-in. |
| Worker dispatch, queues, callbacks | Environment/branch pairing and queue/dispatch contracts have local tests. Manual validation Actions dispatch and real processing succeeded. | Actual Worker-to-GitHub dispatch, provider callbacks, and queue recovery with the necessary dedicated credentials/configuration. |
| Notifications | Validation disables outbound integrations; nonproduction notification records are skipped. | Production provider delivery is not claimed or exercised by validation. |
| Data migration | Source-schema-3 to target-schema-6 converter passes 17 migration tests and a populated local D1 import proof, including foreign keys, derived clips, and safe historical notification handling. | Remote disposable import rehearsal and production-volume data/search measurement. No complete production export or storage copy has been performed here. |
| Weekly dev storage wipe | The workflow and Worker restrict the sweep to dev. The weekly schedule is Sunday 10:00 UTC and remains gated until Cloudflare dev activation. | Existing dev is outside this validation deployment. Validation must not be used to exercise a dev-only wipe. |

## Real recording evidence

All times below are source-relative half-open ranges. Samples are discrete frame-processing ticks.

| Source recording | Verified range | Samples | Detections | Non-null IGD | Actions run |
|---|---:|---:|---:|---:|---|
| Bilibili `BV1FfL5zPEbH:29594289602` | `[600,1500)` of 7,211 seconds | 450 | 4 | 0, disabled | [34147607029](https://github.com/liftaris/bazaar-ghost/actions/runs/34147607029) |
| Bilibili `BV1K114BiE7t:33726794861` | Full `[0,2468)` | 1,234 | 13 | 0, disabled | [34148846218](https://github.com/liftaris/bazaar-ghost/actions/runs/34148846218) |
| YouTube `0C6bxQsDj-s` | Full `[0,2718)` | 1,359 | 13 | 11 | [34150684415](https://github.com/liftaris/bazaar-ghost/actions/runs/34150684415) |
| YouTube `yS_mgLwtITA` | Full `[0,2467)` | 1,234 | 13 | 12 | [34151218515](https://github.com/liftaris/bazaar-ghost/actions/runs/34151218515) |

The full Bilibili upload is a reviewed copy of the second YouTube upload. The three complete source uploads therefore represent two distinct gameplay recordings. Including the earlier interval, validation contains 43 real detections/clips from 4,277 samples. Source durations remain distinct, and the odd-length YouTube run includes its final expected tick at 2,466 seconds.

The synthetic hosted retry proof ran on the exact deployed build from `2026-09-08T00:14:32.849Z` to `00:15:19.811Z` (September 7 locally). It verified removal of five uploaded JPEG objects plus absence of one never-created access probe, zero remaining fixture rows, clean foreign keys, and unchanged full-row hashes for all 43 pre-existing clips and detections. An independent subsequent D1 query confirmed the final counts and one intentionally retained moderation audit. Evidence: `.ignore/platform-validation/hosted-reprocess-smoke.f5cd8059-2c6d-434f-b379-5ca162e4556f/{proof.json,independent-cleanup-proof.json}`.

## Dependencies for remaining hosted work

Dedicated provider applications and user consent are needed for [real OAuth acceptance](user-auth.md#verification-and-remaining-acceptance). Outbound enablement must be reviewed alongside pending ingestion work because the same switch controls multiple integrations. Existing provider callbacks must remain unchanged.

Unattended deployment requires the dedicated validation Cloudflare CI credential. Worker dispatch also needs a repository-scoped Actions-write credential. Local Wrangler reauthentication restored management access and deployment; it does not establish either automation credential.

A separate temporary database was prepared for remote import rehearsal, but automatic approval review rejected resource creation pending explicit permission. No such database was created, and that approval remains pending. This does not prevent work in the already provisioned validation environment.

Public recording access is a separate dependency: successful manual extraction from a disposable Actions runner does not establish reliable automatic provider polling. Current failures and bounded retry behavior are recorded in [platform-ingestion.md](platform-ingestion.md).

Private fixture scripts and detailed evidence live under `.ignore/platform-validation/`. They are not application login endpoints and must not be represented as real OAuth or real-media OCR. Successful fixture cleanup must verify exact owned rows and objects are absent while preserving the pre-existing real recording data.
