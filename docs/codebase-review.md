# Codebase review: current, intended, improved

Review performed on the clean `dev` baseline in local branch `codex/codebase-cleanup`. The unit of correctness is a searchable opponent appearance tied to the actual VOD frame, not merely a container that exits successfully.

## What the system needs to guarantee

- Only eligible Bazaar footage is scheduled. Streamer enablement, VOD readiness and availability are independent gates.
- A chunk has one active owner. Retries preserve the work identity and cannot corrupt sibling chunks.
- A timestamp belongs to its pixels, even under backpressure or an HLS seek that starts between segment boundaries.
- OCR sees the bounded opponent nameplate. Rank, confidence, truncation and optional day remain explicit evidence.
- Completion means the decoder and OCR workers finished and every accepted detection was persisted. Infrastructure/inference errors are different from “no matchup.”
- Search remains public; catalog mutation, processing control and notification administration require the service credential or provider signature.

## Findings and resulting changes

| Area | Baseline behavior | Resulting behavior |
|---|---|---|
| Video timing | Streamlink's rounded segment start fed a rebased pipe; images and timestamps traveled separately | Resolve the selected playlist, accurately seek with FFmpeg, pair each JPEG with its PTS before queuing |
| Worker lifecycle | EOF and shutdown shared state; queue pressure could lose frames; final results could be abandoned | Separate EOF/cancellation signals, bounded queues with backpressure, one deadline, propagated failures, final batch drain |
| False success | Decoder/OCR/storage errors could become empty results or successful chunks | Required work failures fail the chunk; empty/invalid crops and ordinary no-text results remain normal negatives |
| Ownership | Non-atomic status updates and cleanup before exclusive ownership | Atomic pending/queued claim, attempt increment, bounded lease, cleanup after claim, expired-work recovery |
| Chunk planning | Nominal one-hour defaults, oversized chunks and discarded short gaps; preview diverged | Shared preview/insertion planner, default maximum 1,800 seconds, short tails retained, existing ranges subtracted |
| VOD state | A VOD failure could rewrite successful sibling chunks | Aggregate VOD state derives from individual chunks; removed destructive reverse propagation |
| Disabling processing | Could delete chunks underneath running workers | Preserve records and identities; eligibility blocks future claims |
| Nameplate bounds | Detected/custom right edge was not consistently used; invalid crop could read unrelated pixels | The actual edge bounds OCR; empty/inverted crop is rejected |
| Template matching | Nonfinite normalized scores on blank masked areas could look like a match | Reject nonfinite scores; validate complete template sets and actual search-region dimensions |
| OCR acceptance | Failed reads consumed cooldown; timestamp zero was suppressed; sustained screens repeated | Accept valid confidence/name first; initial timestamp is eligible; sustained-screen latch resets when emblem disappears |
| Day extraction | EOF could lose pending results; a new matchup could contribute its day to the previous one | Flush pending username at EOF/timeout; never scan a newly detected matchup for the previous opponent |
| Persistence | Insert could precede screenshot; retry could duplicate an insert/notification; lookup failure could silently skip | Screenshot first, stable detection IDs, conflict-safe retries, propagated lookup/upload failure, paged cleanup |
| Twitch availability | API failure could mark VODs unavailable; repeated IDs were incorrectly encoded | Distinguish outage from an authoritative empty response and preserve repeated query parameters |
| Cataloging | Duplicate implementations, a disabled/commented endpoint, loose game-name matching | Shared cataloger with dry run, exact Bazaar identification, sorted/clamped/merged ranges, actual endpoint behavior |
| Long chapter lists | First 25 markers could silently imply an incorrect final-game tail | Fail explicitly at the query limit instead of scheduling from incomplete evidence |
| Dispatch | Repeated scheduling could duplicate work; failed preparation could damage unrelated VOD/chunk state | Conditional pending-to-queued transition, matrices capped at 256, rollback scoped to the dispatch timestamp/IDs |
| Workflow inputs | Shell interpolation, ignored quality, optional profile despite runtime need, invalid empty-work status | Python input validation, selected rendition/FPS, database profile fallback, empty matrix skipped, pre-cutoff templates inferred |
| Access | Localhost bypass and permissive catalog/control-plane mutation paths | Secret validation without bypass; administrative RPC grants and table writes restricted to service role |
| Discord | Case-sensitive subscription lookup, DM identity gaps, unrestricted channel configuration, inaccurate delivery counts | Case-folded lookup, correct interaction identity, guild permission checks, count successful deliveries, suppress automatic mentions |
| Telemetry | Wrong OTLP metric shapes/temporality, untracked export promises, unconditional shutdown delay | Real delta counters/histograms, bounded optional export, edge lifetime registration, contextual JSON logs, no fixed sleep |
| Packaging | Fake healthcheck, repeated dependency setup, incorrect test model home, runtime pytest installation | One-shot non-root image, cached runtime-user models, separate offline test target |
| Maintenance | Stale SFOT names; schema wipe before restore; non-paginated/infinite-retry storage cleanup | Current-schema catalog export, transactional data import preserving schema/Vault, paged dry-run-first bucket cleanup |
| Deployment | Independent automatic migration/function workflows could race | Automatic deployment applies migrations before dependent functions; manual migration workflow retained |

The implementation keeps OpenCV templates and PaddleOCR. The labeled corpus supports those choices; replacing them with a new model without representative video labels would add uncertainty. Streamer-specific crops, old UI templates, debug screenshots, rank/truncation metadata, and public search contracts remain useful and are retained. Uncalled detector visualization/masking methods and telemetry wrappers were removed after checking repository references; the production debug rendering uses the coordinates actually used for OCR.

Historical migrations are preserved. The new migration upgrades existing databases rather than rewriting history or regenerating a schema dump. It preserves existing chunk identities and durations: only newly planned gaps use the bounded planner. Privileged catalog/profile editing now requires a service-side path; clients relying on anonymous writes must change accordingly.

## Scope inspected

The review covered every SFDE source module, runtime config, Docker/Compose/build setup, detector templates and labeled-fixture paths; all edge entrypoints and shared modules; all migration files and application functions/triggers/policies; workflow definitions and helper scripts; fixture/report tooling; and the root/SFDE documentation. The frontend is not in this repository.

Useful ancillary features remain: Discord search/notifications, availability filtering, chat mention search, profile/date metadata, and catalog export. Chat upstream errors now fail visibly instead of masquerading as empty chat. Chat search remains an offset-based, page-capped ancillary task, not part of matchup accuracy validation.

## Validation evidence

All experiments used `.ignore/cleanup/`. The database was a separate local Supabase project (`bazaar-ghost-cleanup`, API port 54421), with no production settings, Vault secrets, or outbound notification configuration. Generated localhost credentials were passed directly into the test process without being saved or printed.

- **Baseline:** all 64 existing SFDE tests passed before editing. This established behavior, not exhaustive correctness.
- **CV/OCR and runtime:** all **95 tests passed** in the final image (60.50 seconds). This includes the original labeled corpus plus timestamp, queue, failure, crop, duplicate-suppression, day-association and persistence regressions offline. Missing validated fixtures fail collection.
- **Real video:** a local HLS stream with a color transition verifies a seek at second 5 across four-second segment boundaries; emitted timestamps and pixels agree.
- **Real chunk:** a 12-second synthetic video contains the validated `217270_314.jpg` frame. Six samples produce one `sakura.` / diamond detection, its screenshot, and a completed chunk using actual FFmpeg, OpenCV, PaddleOCR, PostgREST and Storage. Reprocessing exercises removal/replacement of the prior local result.
- **Database:** a clean local reset applies the full migration chain; 23 transactional pgTAP assertions cover bounded planning, tails, ownership, attempt count, sibling preservation, permissions, lease recovery, disabling, preview consistency and empty chapters.
- **Control plane:** eight Deno tests cover authentication, chapters, Twitch outages and repeated IDs, EventSub HMAC freshness, dispatch batching/rollback and OTLP encoding/failure. Network calls are mocked. Every entrypoint type-checks; lint follows the repository's explicit `any` catch/type and runtime-import conventions.
- **Workflow helpers:** rendition-selection tests cover requested quality, old templates, unsupported aliases and unavailable renditions. Bash syntax and workflow YAML are checked locally.
- **Seed round trip:** generate catalog SQL from synthetic local records and restore it successfully in one transaction; no remote seed or sync command is executed.

## Practical limits and deployment notes

These changes improve correctness and failure visibility; they do not establish a new production recall or precision figure. The fixture corpus is finite, 0.5 FPS can miss shorter screens, rank templates can drift with game UI changes, and an occluded name can remain truncated. In-game day remains optional, high-confidence OCR of the configured region.

Live Twitch access, GitHub dispatch, Discord delivery and Grafana ingestion were not exercised against external services. Twitch's chapter/chat GraphQL interface is an external dependency; VODs reaching the 25-marker query limit now require explicit handling rather than silently trusting truncated data. The webhook still performs synchronous catalog/dispatch work; provider retries are mitigated by conditional claims but this is not a durable event inbox. The scheduler's capacity is a dispatch target, not a global hard concurrency semaphore across simultaneous scheduler calls.

Existing local JWT gateway settings are unchanged. Hosted deployment already uses application authentication with `--no-verify-jwt`; that flag was not introduced by this cleanup. Automatic deployment now orders migrations first. Validate the branch in dev before the maintainer merges it to main. Nothing was pushed or deployed during this local review.

Accurate playlist seeking follows [FFmpeg's input seeking behavior](https://ffmpeg.org/ffmpeg.html) and [Streamlink's stream URL mode](https://streamlink.github.io/cli.html#cmdoption-stream-url). Metric encoding follows the [OpenTelemetry data model](https://opentelemetry.io/docs/specs/otel/metrics/data-model/).
