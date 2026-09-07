# Multi-platform backend validation

Tested on 2026-09-07 against local Supabase and local Docker. Production and the frontend were untouched. The feature branch is `codex/multiplatform-backend`; no GitHub deployment was executed.

## Real recordings

Every row ran the complete worker: public media resolution, FFmpeg seek/scale/crop, emblem detection, PaddleOCR, storage upload, detection insertion, and chunk completion. Each range contains 900 source seconds and produced 450 frames at the existing 0.5 FPS setting.

| Recording | Source range | Templates | Resolver/input | Saved appearances |
|---|---:|---|---|---:|
| [Kripp: Pendulum](https://www.youtube.com/watch?v=0C6bxQsDj-s) | 0–900 s | Current | Streamlink, 360p → 480p | 4 |
| [Retromation: Karnok](https://www.youtube.com/watch?v=c0FuhNNxdF0) | 600–1500 s | Current | Streamlink, 360p → 480p | 3 |
| [Kripp: February 2025 archive](https://www.youtube.com/watch?v=RPugJRVU6Zg) | 3600–4500 s | Old | Streamlink, 360p → 480p | 4 |
| [小和尚济海: April 2025 replay, part 2](https://www.bilibili.com/video/BV1FfL5zPEbH/?p=2) | 600–1500 s within part 2 | Old | Bundled Streamlink adapter, 480p | 4 |
| [Bilibili upload: Kripp Feast](https://www.bilibili.com/video/BV1K114BiE7t/) | 0–900 s | Current | Bundled Streamlink adapter, 480p | 3 |
| [Original YouTube: Kripp Feast](https://www.youtube.com/watch?v=yS_mgLwtITA) | 0–900 s | Current | Streamlink, 360p → 480p | 3 |

**Total: 90 minutes of source footage, 2,700 frames, 21 saved source appearances.** These are detections found, not a measured recall claim: the entire sample was not manually annotated for every possible missed matchup.

The nonzero YouTube and Bilibili starts verified source-relative timestamps. The Bilibili replay uses `BV1FfL5zPEbH:29594289602`; its part lasts 7,211 seconds independently of the submission's other two parts. Its embed URL includes this `cid` rather than relying on part position.

A stored screenshot from Kripp's current upload was visually checked against its OCR result (`abccbaaaa`, 218 s). Public local storage reads succeeded. Detection paths include the correct source namespace and persisted rows use internal video IDs.

## Real cross-platform overlap

The Feast upload exists on both tested platforms. Independently processing each produced:

| Opponent | YouTube time | Bilibili part time | Rank |
|---|---:|---:|---|
| arpuc | 322 s | 322 s | Bronze |
| PatoPapao | 540 s | 540 s | Bronze |
| Raff | 740 s | 740 s | Bronze |

Full frames extracted at 322 s show the same gameplay, opponent panel, camera pose, overlay clock, and transition. Combined with the same ordered three-event sequence, this supplied evidence for linking these specific copies. Three verified groups were written locally; each grouped search result retained one YouTube appearance and one Bilibili appearance. This leaves 18 groups across the 21 test appearances.

This was a reviewed test pair, not an automatic duplicate detector. No title-based or username-only automatic merging was enabled. Database fixtures separately verified unlinking, grouping before pagination, anonymous write restrictions, and continued searchability after one source becomes unavailable.

## Catalog and HTTP checks

- A real Kripp channel backfill ran twice with `--limit 1`. The stored cursor advanced from 1 to 2 to 3, and the second call cataloged the next upload (`FwFtvty14hk`).
- Rediscovering `0C6bxQsDj-s` retained its internal ID, its completed 0–900 s chunk, and its verified gameplay range. The full duration was not substituted for that range.
- The real `process-vod` Deno HTTP handler returned a YouTube dry-run plan for the next upload with two pending chunks. An unauthenticated POST returned 401. The server's network permission allowed only localhost Supabase and its local listener; no GitHub dispatch occurred.
- The installed standard Bilibili yt-dlp page extractor returned HTTP 412 for the upload. The bundled Streamlink UGC adapter successfully used public metadata and anonymous playback instead. This is a tested fallback implementation choice, with no guarantee that the same access will hold on every runner/network.

## Automated checks

| Check | Result |
|---|---|
| Complete offline SFDE suite, final platform worker image | 96 passed |
| Python catalog/resolver/workflow/ingestion tests | 33 passed |
| Shared Deno tests including signed YouTube callbacks | 13 passed |
| Local PostgreSQL/pgTAP contracts | 78 passed across six files |
| All edge-function type checks | Passed |
| Deno lint | Passed |
| Changed workflow YAML parsing | Passed |
| Whitespace/diff checks | Passed |

The SQL checks include 23 existing processing contracts, 5 existing search contracts, 14 YouTube contracts, 9 Bilibili contracts, 10 overlap contracts, and 17 automatic-ingestion contracts. All fixtures roll back. New migrations were created through the Supabase CLI and applied additively to local Supabase. The 96-test SFDE image result is from the prior media implementation; the ingestion follow-up changed no SFDE worker code and reran the affected Python, Deno, and SQL checks.

The local CLI's `supabase test db` wrapper encountered a Docker-network naming mismatch; the same pgTAP SQL files were executed directly through `psql` in the verified local database container, and all TAP results were checked. This did not require resetting existing local data.

Scratch logs, metadata, summaries, and comparison images are under `.ignore/youtube/`. They are gitignored and are not part of the implementation commit. They contain expiring playback locators in some raw extractor responses; local database keys were held in memory and were not saved there.

## Not yet validated

GitHub-hosted playback, real Google hub subscription/renewal, a real stream finishing during unattended operation, sustained catalog operation, rate limits under load, Chinese in-game OCR, reliable arbitrary Bilibili uploader enumeration, automatic availability recovery, same-duration edit detection, and automatic overlap alignment remain outside these test results. See [multiplatform-backend.md](multiplatform-backend.md) for the implemented operating scope.

## Automatic ingestion follow-up

The new [ingestion worker](platform-ingestion.md) was exercised with public metadata and the confirmed local Supabase instance:

- Explicit YouTube `@Kripparrian` and Bilibili UID `2663423` enrollment resolved the expected immutable identities and scheduled account scans.
- Bounded recent searches returned 19 YouTube candidates and 13 Bilibili candidates. Two from each were queued and cataloged. MabiVsGames (`UCK79KkzpFhr3MntmZFGN6-g`) and `_yswc` (`631453528`) were enrolled automatically from verified metadata.
- Four source candidates completed: `AI_UwoktAGE`, `FwFtvty14hk`, `BV1XQbT6QEvj`, and `BV1cvbT6eEm7`. This inserted three new playable source rows and refreshed the existing Kripp upload. No additional SFDE footage was processed in this follow-up.
- Real YouTube `videos` and `streams` catalog scans worked for Kripp. Retromation's explicit missing-streams-tab response exposed an upload-only account case, which was fixed and rechecked against that channel; it now returns an absent tab without hiding network failures.
- Bilibili uploader `2663423` succeeded during the integrated run after earlier HTTP 412/API rejection failures. Uploader `2561817` remained blocked and retained a waiting job with an error. General uploader reliability is not established.
- The local HTTP YouTube callback returned 200 for a pending verification, 404 for its repeated completed challenge, 403 for unsigned delivery, and 204 for signed delivery. Replaying that body left one receipt and one video job. Wrong-account XML returned 400; hub denial was recorded; expired delivery returned 403; a disabled account returned 404. Temporary fixtures were removed after the check.
- The new due-work RPC selected pending YouTube and Bilibili videos. The actual `process-vod` HTTP handler produced dev dry-run plans with two, one, and two chunks; an explicit environment mismatch returned 409. The server's network permissions allowed only localhost, preventing external dispatch.
- Local vault-secret and cron-job counts were both zero. No external hub subscription, GitHub dispatch, Discord message, hosted migration, or deployment occurred.

New scratch evidence is under `.ignore/ingestion/`. Credentials were consumed from local CLI status in memory by a wrapper that rejects non-local API URLs. Public extractor metadata and job summaries were saved; local credentials and subscription secrets were not.
