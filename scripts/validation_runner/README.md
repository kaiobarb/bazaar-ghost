# Temporary validation runner

This runs one **GitHub Actions job** inside the local, tested SFDE container. It is a temporary way to test public YouTube recordings from a network where anonymous metadata/media access succeeds. It does not install anything on the host, use provider cookies, change upstream clients, or move OCR into Cloudflare.

Only `liftaris/bazaar-ghost`, `codex/cloudflare-validation`, `workflow_dispatch`, and `validate-recording.yml` pass the image-owned pre-job hook. The runner has one random label, no default labels, and unregisters after one job. Its container runs as UID 1000 with dropped capabilities, no Docker socket, no host filesystem mounts, no host home, and no host network mode. All runner credentials and checked-out files live in the disposable container layer. GitHub supplies only the validation environment's catalog/processor capabilities to the processing step; the OCR subprocess receives the processor key alone.

The runner is pinned to the official [v2.337.0 release](https://github.com/actions/runner/releases/tag/v2.337.0), with the release's SHA-256 verified during build. Its registration token is read once from stdin and passed to the official runner as `ACTIONS_RUNNER_INPUT_TOKEN` only for configuration. It is never put in argv, a file, Docker configuration, or printed. The parent process does not pass that variable to the listening runner. See the official [runner argument reader](https://github.com/actions/runner/blob/v2.337.0/src/Runner.Listener/CommandSettings.cs), [ephemeral runner documentation](https://docs.github.com/en/actions/reference/runners/self-hosted-runners#ephemeral-runners-for-autoscaling), and [job hook documentation](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/run-scripts).

## Build and local checks

From the repository root:

```sh
docker build --build-arg BASE_IMAGE=sfde:cloudflare-platform-test \
  -t bazaarghost-validation-runner:2.337.0 scripts/validation_runner
python3 -m unittest discover -s scripts/tests -p test_validation_runner.py
```

The initial built image is `sha256:a517898e645b6b1b5ee62857cecba354c0facdac2bd45dcc66d83a63e088a63c`, based on tested SFDE image `sha256:96a66467eeb001026541e5b0025ae081c9c499f1fee85cd2decfe806944b58c6`. Offline container checks confirmed UID 1000, GitHub runner 2.337.0, Deno 2.9.5, Python OCR imports and cached models. The workflow executes `sfde/src/sfde.py` from the exact dispatched checkout, so runtime packages/models come from the image while detector code and templates come from the reviewed commit.

## Operator steps

1. Commit and push these files to `codex/cloudflare-validation`. Its path-scoped push trigger registers the workflow with GitHub but deliberately skips its sole job. No default-branch workflow or environment changes are needed. Ensure the validation Worker and migrations are deployed and its GitHub environment has `BAZAARGHOST_API_URL`, `BAZAARGHOST_CATALOG_KEY`, and `BAZAARGHOST_PROCESSOR_KEY`.
2. Review one public YouTube video, its exact gameplay ranges, template era, and an existing validation crop profile. Ranges must be sorted/nonoverlapping, at most 1800 seconds each, at most three ranges and 3600 seconds total. Use 480p for old templates. The profile must already exist; the runner has no admin key and cannot create profiles.
3. Create a private task directory and input document. The example values below are placeholders for reviewed content; no secret belongs in this document:

```sh
mkdir -p .ignore/validation-runner
chmod 700 .ignore/validation-runner
python3 - <<'PY'
import json, pathlib, uuid
path = pathlib.Path('.ignore/validation-runner')
label = 'bazaarghost-validation-' + uuid.uuid4().hex
(path / 'label').write_text(label + '\n')
inputs = {'runner_label': label, 'source': 'youtube', 'video_id': 'REVIEWED_ID',
          'ranges': '[0,900]', 'templates': 'current', 'profile_id': '1',
          'quality': '480p', 'recorded_at': '', 'minimum_detections': '1', 'require_igd': 'true'}
(path / 'inputs.json').write_text(json.dumps(inputs))
PY
```

4. Start a single ephemeral runner. The registration response flows directly through stdin. Do not enable shell tracing. This terminal remains attached until the job ends:

```sh
VALIDATION_RUNNER_LABEL="$(cat .ignore/validation-runner/label)"
gh api --method POST repos/liftaris/bazaar-ghost/actions/runners/registration-token --jq .token \
  | python3 scripts/validation_runner/launch.py --label "$VALIDATION_RUNNER_LABEL"
```

5. Once it reports that it is awaiting the job, dispatch from a second terminal:

```sh
gh workflow run validate-recording.yml --repo liftaris/bazaar-ghost \
  --ref codex/cloudflare-validation --json < .ignore/validation-runner/inputs.json
```

The launcher uses a disposable container with 4 CPUs, 12 GiB memory, 2 GiB shared memory and a 512-process limit. It never invokes sudo. Its image must already exist locally (`--pull=never`). A new recording/job requires a new random label and fresh ephemeral container.

## What success proves

The single job verifies the backend's validation identity before sending capabilities, catalogs only the reviewed video/ranges, resolves its media, and processes planned chunks sequentially. It refuses pre-existing completed/failed/queued work or a plan that does not exactly cover the reviewed ranges. To retry failed work, an operator must explicitly reset that validation VOD through the existing admin API before starting another runner; no state-reset authority is given to the runner.

For each chunk it requires completed backend state, the exact expected frame count, and decoder timestamps covering the entire sampled timeline. A 900-second range requires 450 samples at two-second intervals, including the expected first and last timestamps. It compares persisted chunk detection counts with the OCR summary, checks every high-confidence detection's name/rank/day through the public API, and fully decodes every JPEG with Pillow, bounded to 5 MB and 16 million decoded pixels. The public detection set must exactly match the high-confidence OCR results, and the backend build must remain unchanged during the run. `require_igd=true` additionally requires at least one extracted day. The VOD must reach `completed`.

Artifacts contain `validation.json` plus the per-chunk OCR JSON reports for seven days. They record the checked-out commit, deployed Worker commit, precise ranges, full-source-video versus selected-range coverage, frame counts/timestamps, public detection totals, IGD totals and verified screenshot paths/dimensions. Adjacent reviewed ranges are merged when determining whether the entire source upload was covered. A completed selected range is explicitly distinguished from processing the entire source upload. Public results and screenshots still require human spot-checking for OCR accuracy; successful transport and persistence do not prove every reading is correct.

## Cleanup and limits

GitHub automatically deregisters a successfully assigned ephemeral runner after its one job; `docker run --rm` removes its container and credentials afterward. If cancelled before receiving a job, stop its container and remove the stale runner registration through the repository runner API. Verify names before deleting an entry:

```sh
docker stop --timeout 60 "$VALIDATION_RUNNER_LABEL"
gh api repos/liftaris/bazaar-ghost/actions/runners --jq '.runners[] | {id,name,status,busy}'
# Only if the exact temporary runner remains:
gh api --method DELETE repos/liftaris/bazaar-ghost/actions/runners/REVIEWED_RUNNER_ID
```

The image and private task input files may be retained for another reviewed run. No host credentials are copied into either. This is a temporary validation path, not a deployed autoscaling service. A future GitHub runner release may require rebuilding the pinned image; GitHub can stop dispatching to sufficiently old runners. No hosted registration, dispatch or OCR run was performed by the image-building helper itself.
