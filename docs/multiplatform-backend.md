# Multi-platform backend: YouTube and Bilibili

Implemented and tested locally on 2026-09-07. The implementation extends the existing SFDE worker and Supabase backend. The website remains on its existing Twitch contracts. No production project was modified or deployment performed.

The original design research is in [multiplatform-spike.md](multiplatform-spike.md). This document describes the implemented first backend release, including its limits.

## Supported ingestion

| Source | Catalog input | Processing identity | Media path |
|---|---|---|---|
| Twitch | Existing discovery, EventSub, and VOD catalog | Existing numeric source ID | Streamlink → FFmpeg |
| YouTube | Explicit enrollment, game-video discovery, signed WebSub, scheduled channel polling, and manual backfills | Case-sensitive video ID | Streamlink → FFmpeg; yt-dlp fallback when Streamlink cannot resolve |
| Bilibili | Uploader enrollment/polling, game-video discovery, and curated BV/part backfills | `BV:cid`, independent of part position | Bundled Streamlink UGC adapter → FFmpeg |

YouTube uploads and finalized livestream archives are supported. The automatic ingestion queue retains active streams, scheduled videos, and archives still processing for later readiness checks. The manual one-shot catalog command skips them. Metadata extraction uses yt-dlp; it does not download a video during cataloging. The worker resolves a fresh media URL for each chunk.

The complete enrollment, notification, polling, discovery, scheduling, and retry contract is in [platform-ingestion.md](platform-ingestion.md), including the difference between stream end and replay publication. Its implementation is locally validated; hosted scheduling and a real Google hub callback have not been activated in this task.

Bilibili supports public ordinary uploads and published replay submissions. Each `cid` gets a separate `vods` row, its own duration, and a timeline starting at zero. Part order is metadata, not identity. Unpublished replay dashboards, active live rooms, paid/supporter-only media, interactive videos, and legacy fragmented FLV playback are excluded. The adapter checks that playback duration matches the complete part, rejecting previews.

Bilibili's built-in Streamlink plugin is live-room-only. `sfde/streamlink_plugins/bazaar_bilibili.py` adds published video parts using public web metadata and anonymous H.264 DASH files. These endpoints are not a contracted developer API. Access can vary by network and platform changes; extraction errors fail the chunk without declaring the video deleted. No cookies, login session, proxy rotation, or premium access was used in the local tests.

The tested YouTube videos resolved directly through Streamlink 8.5.0, despite the plugin documentation's live-only description. Streamlink exposed 360p for those videos; FFmpeg normalized it to the 480p template geometry. Bilibili resolved 480p. The optional YouTube fallback can be disabled with `YOUTUBE_ALLOW_YTDLP=false`.

## Catalog and backfill commands

Supply `SUPABASE_URL` and `SUPABASE_SECRET_KEY` from the environment you explicitly intend to use. The scripts do not source `.env` files. For development, use local Supabase or `.env.dev`.

Apply the migrations locally first:

```sh
supabase migration up --local
```

Catalog a YouTube upload:

```sh
python scripts/catalog_youtube.py \
  --video 'https://www.youtube.com/watch?v=0C6bxQsDj-s' \
  --enable-processing
```

Inspect a bounded channel page without writing:

```sh
python scripts/catalog_youtube.py \
  --channel 'https://www.youtube.com/@Kripparrian' \
  --tab videos --limit 5 --dry-run
```

Resume a channel backlog using the platform account UUID returned by a prior catalog run:

```sh
python scripts/catalog_youtube.py \
  --account '<platform-account-uuid>' --mode backfill --tab videos --limit 10
```

`videos` and `streams` have separate stored cursors. A cursor advances only after the complete page persists. Recent scans always start at the first page. Inserts are idempotent on `(source, source_id)`; rediscovery preserves existing chunks, verified gameplay ranges, and template/date overrides. Playlist ordering can change: periodically rescan recent items, and restart a bounded backlog scan if upstream deletions/reordering make positional coverage uncertain. Metadata failures leave the page cursor unchanged and surface a failed command for operator retry.

Catalog a Bilibili replay part:

```sh
python scripts/catalog_bilibili.py \
  --video 'https://www.bilibili.com/video/BV1FfL5zPEbH/?p=2' \
  --templates old --enable-processing
```

A bare BV ID enumerates its parts, up to `--limit` (maximum 50). The output includes a resume video and `start_part` when the bound is reached:

```sh
python scripts/catalog_bilibili.py \
  --video BV1FfL5zPEbH --start-part 2 --limit 2 --templates old
```

Repeat `--video` for a curated batch of submissions. Automatic recent uploader enumeration is implemented separately in the ingestion worker. Its public extractor can be blocked; one local uploader poll succeeded and another failed with a durable retry. Complete historical uploader enumeration is not claimed.

Both catalog commands accept `--profile-id`, optional `--streamer-id`, `--ranges '[600,1500]'`, `--templates old|current|auto`, and `--dry-run`. Manual catalog accounts begin disabled unless explicitly enabled. The separate enrollment command and verified automatic discovery enable new accounts, preserving existing operator disables. Enabled accounts receive polling jobs. Cataloging an enabled source creates any missing chunks. New catalog work has priority `-10`, below ordinary Twitch work.

Title/tag evidence identifies YouTube Bazaar candidates; Bilibili accepts `Bazaar` or `大巴扎` in submission/part titles. Titles are a coarse admission signal, not a classifier for every frame. Use verified ranges for mixed-game recordings. `--assume-bazaar` is an explicit operator override.

## Dates, layouts, and revisions

`published_at` describes publication. `recorded_at` is optional and describes the start of the specific playable timeline. YouTube/Bilibili gameplay dates remain unknown unless explicitly supplied. A Bilibili `--recorded-at` requires a single explicit part; the same recording start is never copied blindly across several parts.

`template_version` explicitly selects old or current templates. In `auto`, Twitch retains its existing publication cutoff. YouTube/Bilibili use a known recording date; without one they default to current templates. **Use `--templates old` for known pre-August-12-2025 footage**, including a recent upload of an old stream. Old templates always use 480p.

Accounts have independent processing enablement and SFDE profiles. A Twitch streamer link is optional and should only represent a verified creator relationship; a reuploader is not automatically the original streamer. A video can override its account profile through `vods.sfde_profile_id`.

Recataloging refuses to change duration or explicit gameplay ranges once chunks exist. Inspect and explicitly reprocess a revised timeline instead of silently retaining stale timestamps. Same-duration edits cannot currently be detected automatically. Bilibili replacement with a different `cid` creates a distinct identity; resolving a removed `cid` fails instead of substituting another part.

The OCR alphabet is unchanged. The tested native Bilibili replay used Latin in-game usernames. Chinese uploader names are preserved, but recognizing arbitrary Chinese in-game names is not claimed by this release.

## Processing and backend contracts

`vod_processing_context` is a service-role view containing the normalized account enablement, profile, template era, and platform. Chunk creation, claims, pending selection, scheduler planning, and force processing now work by internal video ID for all three sources.

The existing authenticated `process-vod` endpoint accepts either an internal `vod_id` or a scoped external identifier:

```json
{"source":"youtube","source_id":"0C6bxQsDj-s","dry_run":true}
```

```json
{"source":"bilibili","source_id":"BV1FfL5zPEbH:29594289602","dry_run":true}
```

`process-vod.yml` accepts the same platform and dispatches bounded matrices with at most four simultaneous workers per workflow. Workers derive source identity from their chunk record. Direct Docker runs still require `CHUNK_ID`, `SFDE_PROFILE`, `QUALITY`, and the appropriate `OLD_TEMPLATES` setting. The source media locator and playback headers are never persisted as catalog metadata.

The new `catalog-youtube.yml` and `catalog-bilibili.yml` are manual **dev-only** workflows. They must be present on the selected GitHub ref before execution. The shared dispatcher still selects `dev` or `main` from its environment; local validation did not dispatch GitHub jobs or change either deployment branch.

Public backend readers:

- `video_detections`: raw available source appearances, including source, creator, part identity, source timestamp, image path, external link, and supported embed URL.
- `search_video_detections`: username substring search with source/account/internal-video filters and bounded pagination.
- `search_matchup_appearances`: verified groups with every available appearance, grouping before pagination and returning the grouped total count.

These are accessible through Supabase REST/RPC with the publishable key. Bilibili external links use the current `p`; its embed URLs use stable `cid` and part-relative seconds. The existing `detection_search`, `detection_search_debug`, `vod_stats`, and `vod_embed_info` remain Twitch-only, preventing the current website from opening a non-Twitch ID in its Twitch player.

New screenshot paths include the platform, e.g. `/detections/youtube/0C6bxQsDj-s/218.jpg`. Existing Twitch paths are preserved. Detection UUIDs remain deterministic per chunk/timestamp, so lost-response retries do not create duplicate rows.

## Verified overlap

Raw observations are retained. The system never merges results solely because opponent names repeat.

After reviewing the footage, service-role callers can use:

```sql
SELECT link_matchup_appearances(
  ARRAY['<first-detection-uuid>', '<second-detection-uuid>']::uuid[],
  'Reviewed the same matchup frame and surrounding gameplay in both sources'
);
```

Linking is idempotent, requires at least two videos and an evidence note, and rejects conflicting existing groups. `unlink_matchup_appearance(uuid)` reverses a link without deleting the detection. Anonymous callers can read grouped results but cannot link or unlink them. If one source becomes unavailable, another available appearance keeps the group searchable.

Automatic video alignment, image fingerprinting, duplicate-candidate ranking, and OCR reuse are not implemented. Verification is currently an operator decision. The stored group structure gives those future stages a reversible destination.

## Operational scope and validation

Automatic discovery, account polling, archive readiness retries, and a dev ingestion workflow are implemented; see [platform-ingestion.md](platform-ingestion.md) for activation and measured access limits. Recataloging refreshes reachable media; transient resolution errors do not mark videos deleted. Source removal can be recorded through the existing `vods.availability` field. Automatic removal/recovery classification and same-duration edit detection remain follow-up work before unattended production operation.

YouTube/Bilibili detection notifications are suppressed, including historical backfills. Existing Twitch notification behavior remains in place. No Discord messages were sent during testing.

Local validation used a credential wrapper that accepted only `127.0.0.1:54321`/`localhost:54321`, kept local keys in memory, and removed production/telemetry variables from worker environments. Additive migrations and rollback-only SQL tests were used; existing local data was not reset.

The final worker image's complete offline SFDE suite passed: **96 tests**. All edge functions type-checked; Deno lint and shared tests passed. Database tests cover Twitch processing/search compatibility, YouTube independent accounts, Bilibili part reordering, public permissions, and reversible overlap groups. Real recording evidence and final counts are recorded in [multiplatform-validation.md](multiplatform-validation.md).

References: [Bilibili external player contract](https://player.bilibili.com/), [Streamlink plugins](https://streamlink.github.io/plugins.html), [yt-dlp Bilibili implementation](https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/bilibili.py). Playback claims above are local experimental results, not a guarantee of access from GitHub-hosted runners or other regions.
