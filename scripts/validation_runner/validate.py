#!/usr/bin/env python3
"""One reviewed validation recording: real catalog, Actions OCR, persisted coverage evidence."""
import io
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.request import Request

ROOT = Path(__file__).resolve().parents[2]
OCR_OUTPUT = Path('/app/output')
MAX_JPEG_BYTES = 5_000_000
MAX_JPEG_PIXELS = 16_000_000
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'sfde' / 'src'))
from backend_environment import open_backend, verify_backend
from catalog_youtube import ensure_account, normalize_video
from media_source import youtube_metadata
from video_catalog import save_video
import vod_workflow
from guard import validate_job


class ValidationFailure(ValueError):
    """Static operator-facing explanations; never raw upstream responses or credentials."""


def options(values):
    def number(name, low, high):
        value = values.get(name, '')
        if not re.fullmatch(r'[0-9]+', value) or not low <= int(value) <= high:
            raise ValidationFailure(f'Invalid {name}')
        return int(value)
    if values.get('ENVIRONMENT') != 'validation' or values.get('VALIDATION_SOURCE') != 'youtube':
        raise ValidationFailure('This temporary workflow accepts only validation YouTube recordings')
    video = values.get('VALIDATION_VIDEO_ID', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{11}', video):
        raise ValidationFailure('Provide one exact YouTube video ID')
    ranges = json.loads(values.get('VALIDATION_RANGES', 'null'))
    if not isinstance(ranges, list) or not 2 <= len(ranges) <= 6 or len(ranges) % 2:
        raise ValidationFailure('Provide 1–3 reviewed ranges')
    previous, total = 0, 0
    for start, end in zip(ranges[::2], ranges[1::2]):
        if type(start) is not int or type(end) is not int or not previous <= start < end <= 86400 or end - start > 1800:
            raise ValidationFailure('Ranges must be ordered, nonoverlapping, and at most 1800 seconds each')
        previous, total = end, total + end - start
    if total > 3600:
        raise ValidationFailure('At most 3600 gameplay seconds per validation job')
    templates, quality = values.get('VALIDATION_TEMPLATES'), values.get('VALIDATION_QUALITY')
    if templates not in ('old', 'current') or quality not in ('360p', '480p', '720p', '1080p'):
        raise ValidationFailure('Explicit supported templates and quality are required')
    if templates == 'old' and quality != '480p':
        raise ValidationFailure('Old templates require 480p')
    if values.get('VALIDATION_REQUIRE_IGD') not in ('true', 'false'):
        raise ValidationFailure('Explicit IGD expectation is required')
    return {'source': 'youtube', 'video_id': video, 'ranges': ranges, 'templates': templates, 'quality': quality,
            'profile_id': number('VALIDATION_PROFILE_ID', 1, 1_000_000),
            'minimum_detections': number('VALIDATION_MINIMUM_DETECTIONS', 1, 100),
            'require_igd': values['VALIDATION_REQUIRE_IGD'] == 'true',
            'recorded_at': values.get('VALIDATION_RECORDED_AT') or None}


def merged(intervals):
    result = []
    for start, end in sorted(intervals):
        if result and start < result[-1][1]:
            raise ValidationFailure('Overlapping chunks cannot prove coverage')
        if result and start == result[-1][1]:
            result[-1][1] = end
        else:
            result.append([start, end])
    return result


def verify_plan(chunks, selected, vod_id):
    if not 1 <= len(chunks) <= 3 or len({chunk['id'] for chunk in chunks}) != len(chunks):
        raise ValidationFailure('Expected 1–3 distinct unclaimed chunks; reset reviewed failed work explicitly before retrying')
    for chunk in chunks:
        if (chunk['vod_pk'] != vod_id or chunk['source'] != selected['source'] or chunk['vod_id'] != selected['video_id']
                or chunk['status'] != 'pending'):
            raise ValidationFailure('Chunk identity or processing state changed')
    expected = merged(list(zip(selected['ranges'][::2], selected['ranges'][1::2])))
    actual = merged([[chunk['start_seconds'], chunk['end_seconds']] for chunk in chunks])
    if actual != expected:
        raise ValidationFailure('Planned chunks must cover exactly the reviewed ranges')


def verify_chunk(planned, state, summary):
    start, end = planned['start_seconds'], planned['end_seconds']
    expected = math.ceil((end - start) / 2)
    coverage = summary.get('decode_coverage') or {}
    if (any(state.get(field) != planned[field] for field in ('id', 'vod_pk', 'source', 'vod_id', 'start_seconds', 'end_seconds'))
            or any(summary.get(field) != planned[field] for field in ('vod_pk', 'source', 'vod_id'))
            or state['status'] != 'completed' or state['frames_processed'] != expected or summary.get('frames_processed') != expected
            or summary.get('chunk_id') != planned['id'] or summary.get('start_time') != start or summary.get('end_time') != end
            or coverage.get('sampled_frames') != expected or coverage.get('minimum_expected_frames') != expected
            or coverage.get('sample_interval_seconds') != 2 or coverage.get('first_sample_seconds') != start
            or coverage.get('last_sample_seconds') != start + 2 * (expected - 1)
            or coverage.get('requested_start_seconds') != start or coverage.get('requested_end_seconds') != end):
        raise ValidationFailure('Terminal state and complete sampled timeline were not both confirmed')
    if state['detections_count'] != summary.get('matchups_found') or len(summary.get('detections', [])) != state['detections_count']:
        raise ValidationFailure('Persisted chunk detection total differs from the OCR report')
    return {'id': planned['id'], 'start_seconds': start, 'end_seconds': end, 'status': state['status'],
            'frames_processed': expected, 'detections_count': state['detections_count'], 'decode_coverage': coverage}


def public_json(path, data=None):
    base = os.environ['BAZAARGHOST_API_URL'].rstrip('/')
    request = Request(base + path, headers={'Content-Type': 'application/json'},
                      data=None if data is None else json.dumps(data).encode())
    with open_backend(request, timeout=30) as response:
        payload = response.read(2_000_001)
    if len(payload) > 2_000_000:
        raise ValidationFailure('Public evidence response too large')
    return json.loads(payload)


def verify_jpeg(payload):
    """Bound bytes and decoded pixels, then decode the complete JPEG, including its tail."""
    if not payload or len(payload) > MAX_JPEG_BYTES:
        raise ValidationFailure('Required JPEG exceeds the validation byte limit or is empty')
    from PIL import Image
    try:
        with Image.open(io.BytesIO(payload)) as image:
            width, height = image.size
            if image.format != 'JPEG' or not 0 < width * height <= MAX_JPEG_PIXELS:
                raise ValidationFailure('Required screenshot is not a bounded JPEG image')
            image.verify()
        # JPEG verify() alone does not decode the pixel stream; load() catches truncation.
        with Image.open(io.BytesIO(payload)) as image:
            image.load()
        return {'bytes': len(payload), 'width': width, 'height': height}
    except ValidationFailure:
        raise
    except Exception:
        raise ValidationFailure('Required JPEG could not be fully decoded') from None


def processor_environment(prepared, chunk_id):
    # OCR receives the processor capability only. Preserve the container's existing
    # model-cache home; no host home, GitHub registration token, catalog key or telemetry secret.
    allowed = ('PATH', 'HOME', 'LANG', 'LC_ALL', 'TMPDIR', 'PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK',
               'BAZAARGHOST_API_URL', 'BAZAARGHOST_PROCESSOR_KEY', 'ENVIRONMENT', 'GITHUB_ACTIONS', 'GITHUB_REF')
    result = {key: os.environ[key] for key in allowed if key in os.environ}
    result.update(CHUNK_ID=chunk_id, QUALITY=prepared['quality'], VIDEO_FPS=prepared['video_fps'],
                  SFDE_PROFILE=prepared['sfde_profile'], OLD_TEMPLATES=prepared['old_templates'],
                  TEST_MODE='false', OMP_NUM_THREADS='1', OPENBLAS_NUM_THREADS='1')
    return result


def main():
    destination = ROOT / 'validation-output'
    destination.mkdir(mode=0o700, exist_ok=True)
    report = {'status': 'failed', 'phase': 'guard', 'chunks': [], 'screenshots': []}
    try:
        validate_job(os.environ)
        selected = options(os.environ)
        if subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip() != os.environ['GITHUB_SHA']:
            raise ValidationFailure('Checked-out source does not match the dispatched commit')
        report.update(selection=selected, checkout_commit=os.environ['GITHUB_SHA'], actions_run_id=os.environ['GITHUB_RUN_ID'])
        report['phase'] = 'health'
        verify_backend()  # Unauthenticated environment verification precedes either capability.
        report['backend'] = public_json('/health')
        if (report['backend'].get('ok') is not True or report['backend'].get('environment') != 'validation'
                or not re.fullmatch(r'[a-f0-9]{40}', str(report['backend'].get('build_commit', '')))):
            raise ValidationFailure('Expected one identified validation backend build')
        report['phase'] = 'reviewed_catalog'
        metadata = youtube_metadata(selected['video_id'])
        video = normalize_video(metadata, chapters=selected['ranges'], template_version=selected['templates'], recorded_at=selected['recorded_at'])
        account = ensure_account(metadata['channel_id'], metadata.get('channel') or metadata['channel_id'], enable=True, profile_id=selected['profile_id'])
        saved = save_video(video, account, explicit_ranges=True)
        cataloged_ranges = merged(list(zip(selected['ranges'][::2], selected['ranges'][1::2])))
        report.update(vod_id=saved['id'], source_duration_seconds=video['duration_seconds'],
                      cataloged_ranges=cataloged_ranges, full_source_video=cataloged_ranges == [[0, video['duration_seconds']]])
        os.environ.update(VOD_ID=selected['video_id'], VIDEO_SOURCE=selected['source'], REQUESTED_QUALITY=selected['quality'],
                          OLD_TEMPLATES=str(selected['templates'] == 'old').lower(), LOCAL='false', INPUT_CHUNKS='', QUEUED_AT='')
        report['phase'] = 'prepare'
        output = destination / 'prepare.outputs'
        output.write_text('')
        subprocess.run([sys.executable, str(ROOT / 'scripts' / 'vod_workflow.py'), 'prepare'], check=True,
                       cwd=ROOT, env={**os.environ, 'GITHUB_OUTPUT': str(output)}, timeout=180)
        prepared = dict(line.split('=', 1) for line in output.read_text().splitlines())
        ids = json.loads(prepared.get('chunk_uuids', '[]'))
        chunks = [vod_workflow.api(f'chunks/{chunk_id}') for chunk_id in ids]
        verify_plan(chunks, selected, saved['id'])
        profile = json.loads(prepared['sfde_profile'])
        if profile['id'] != selected['profile_id'] or prepared['old_templates'] != str(selected['templates'] == 'old').lower():
            raise ValidationFailure('Prepared profile or template era differs from the reviewed inputs')
        report['profile'] = {key: profile.get(key) for key in ('id', 'profile_name', 'crop_region', 'igd_crop_region', 'scale', 'custom_edge', 'opaque_edge', 'from_date', 'to_date')}
        report['phase'] = 'ocr'
        summaries = []
        for chunk in sorted(chunks, key=lambda item: item['start_seconds']):
            report['current_chunk'] = chunk['id']
            subprocess.run([sys.executable, '-u', 'src/sfde.py'], cwd=ROOT / 'sfde',
                           env=processor_environment(prepared, chunk['id']), check=True, timeout=2000)
            summary = json.loads((OCR_OUTPUT / f'detections_{chunk["id"]}.json').read_text())
            state = vod_workflow.api(f'chunks/{chunk["id"]}')
            report['chunks'].append(verify_chunk(chunk, state, summary))
            summaries.append(summary)
        report['phase'] = 'public_persistence'
        detections = public_json('/rest/v1/rpc/search_video_detections',
                                 {'source_filter': selected['source'], 'video_filter': saved['id'], 'result_limit': 500})
        if any(row.get('vod_id') != saved['id'] or row.get('source') != selected['source']
               or row.get('source_id') != selected['video_id'] for row in detections):
            raise ValidationFailure('Public evidence belongs to another recording')
        visible = {(row['frame_time_seconds'], row['username']): row for row in detections}
        expected = [item for summary in summaries for item in summary['detections'] if item['confidence'] > 0.7]
        if len(detections) != len(expected) or len(visible) != len(expected):
            raise ValidationFailure('Public detection set differs from the fresh OCR result set')
        if len(expected) < selected['minimum_detections']:
            raise ValidationFailure('Reviewed ranges did not produce the required high-confidence detections')
        for item in expected:
            row = visible.get((item['timestamp'], item['username']))
            if not row or row['igd'] != item['igd'] or row['rank'] != item['rank']:
                raise ValidationFailure('A reported detection or its extracted data is missing from the public API')
            path = row['storage_path']
            if not isinstance(path, str) or not path.startswith('/detections/') or '?' in path or '#' in path:
                raise ValidationFailure('Unexpected public screenshot path')
            with open_backend(Request(os.environ['BAZAARGHOST_API_URL'].rstrip('/') + path), timeout=30) as response:
                if response.status != 200 or response.headers.get_content_type() != 'image/jpeg':
                    raise ValidationFailure('A required screenshot is unavailable or is not JPEG')
                dimensions = verify_jpeg(response.read(MAX_JPEG_BYTES + 1))
            report['screenshots'].append({'detection_id': row['detection_id'], 'frame_time_seconds': item['timestamp'],
                                          'storage_path': path, 'igd': row['igd'], 'verified_jpeg': True, **dimensions})
        report['public_detections_verified'] = len(expected)
        report['igd_detections'] = sum(item['igd'] is not None for item in expected)
        if selected['require_igd'] and not report['igd_detections']:
            raise ValidationFailure('No extracted in-game day was observed')
        final = vod_workflow.get_vod()
        if final['status'] != 'completed':
            raise ValidationFailure('The cataloged VOD has not reached completed state')
        report['backend_final'] = public_json('/health')
        if (report['backend_final'].get('ok') is not True or report['backend_final'].get('environment') != 'validation'
                or report['backend_final'].get('build_commit') != report['backend'].get('build_commit')):
            raise ValidationFailure('Backend changed during validation; repeat against one deployed build')
        report.update(status='passed', phase='complete', vod_status=final['status'],
                      frames_processed=sum(chunk['frames_processed'] for chunk in report['chunks']))
    except Exception as error:
        report['error_type'] = type(error).__name__
        if isinstance(error, ValidationFailure):
            report['error'] = str(error)
        print(f'Validation failed during {report["phase"]}: {report.get("error", type(error).__name__)}', file=sys.stderr)
    finally:
        target = destination / 'validation.json'
        target.write_text(json.dumps(report, indent=2) + '\n')
        target.chmod(0o600)
        with open(os.environ.get('GITHUB_STEP_SUMMARY', destination / 'summary.md'), 'a') as summary:
            summary.write(f'Validation **{report["status"]}** at `{report["phase"]}`. '
                          f'{len(report["chunks"])} chunks verified; see the validation artifact for exact ranges and sampled coverage.\n')
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
