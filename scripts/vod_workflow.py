#!/usr/bin/env python3
"""GitHub Actions preparation and reporting; inputs are data, never shell code."""

from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any, Dict, List
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import UUID


SUPPORTED = ('360p', '480p', '720p', '1080p')


def select_quality(streams: Dict[str, Any], preferred: str, old_templates: bool) -> str:
    base = preferred.removesuffix('60')
    if base not in SUPPORTED:
        raise ValueError(f'Unsupported quality: {preferred}')
    candidates = ['480p', '480p60'] if old_templates else [
        preferred, f'{base}60', base, '480p', '480p60', '720p', '720p60',
        '1080p', '1080p60', '360p', '360p60',
    ]
    for candidate in candidates:
        if candidate in streams:
            return candidate
    raise ValueError('No supported rendition is available for these templates')


def api(path: str, params: Dict[str, str] = None, body: Any = None, method: str = 'GET') -> Any:
    url = os.environ['BAZAARGHOST_API_URL'].rstrip('/') + '/api/processor/' + path
    if params:
        url += '?' + urlencode(params)
    key = os.environ['BAZAARGHOST_PROCESSOR_KEY']
    request = Request(url, method=method, headers={
        'apikey': key, 'Authorization': f'Bearer {key}', 'Content-Type': 'application/json',
        'Prefer': 'return=representation',
    }, data=None if body is None else json.dumps(body).encode())
    with urlopen(request, timeout=30) as response:
        data = response.read()
    return json.loads(data) if data else None


def input_chunk_ids() -> List[str]:
    ids = json.loads(os.getenv('INPUT_CHUNKS') or '[]')
    if not isinstance(ids, list) or any(not isinstance(value, str) for value in ids):
        raise ValueError('chunk_uuids must be a JSON array of UUIDs')
    return list(dict.fromkeys(str(UUID(value)) for value in ids))


def get_vod() -> Dict[str, Any]:
    source_id = os.environ['VOD_ID']
    if not re.fullmatch(r'\d+', source_id):
        raise ValueError('VOD_ID must be numeric')
    return api('vod', {'source_id': source_id})



def output(name: str, value: Any) -> None:
    encoded = value if isinstance(value, str) else json.dumps(value, separators=(',', ':'))
    if '\n' in encoded or '\r' in encoded:
        raise ValueError('Workflow outputs must fit on one line')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as destination:
        destination.write(f'{name}={encoded}\n')


def prepare() -> None:
    vod = get_vod()
    streamer = vod['streamers']
    if not streamer['processing_enabled'] or not vod['ready_for_processing'] or vod['availability'] != 'available':
        raise ValueError('VOD is not eligible for processing')
    requested_ids = input_chunk_ids()
    params = {'vod_id': str(vod['id'])}
    if requested_ids:
        params['ids'] = json.dumps(requested_ids)
    if os.getenv('QUEUED_AT'):
        params['queued_at'] = os.environ['QUEUED_AT']
    chunks = api('chunks', params)
    ids = [chunk['id'] for chunk in chunks]
    if len(ids) > 256:
        raise ValueError('More than 256 chunks; dispatch bounded batches through process-vod')
    output('chunk_uuids', ids)
    if not ids:
        return
    profile = json.loads(os.environ['SFDE_PROFILE']) if os.getenv('SFDE_PROFILE') else streamer['sfde_profiles']
    if not isinstance(profile, dict) or not isinstance(profile.get('crop_region'), list):
        raise ValueError('A valid SFDE profile is required')
    published = vod.get('published_at')
    old = os.getenv('OLD_TEMPLATES') == 'true' or bool(
        published and datetime.fromisoformat(published.replace('Z', '+00:00')) < datetime(2025, 8, 12, tzinfo=timezone.utc)
    )
    output('old_templates', str(old).lower())
    preferred = os.getenv('REQUESTED_QUALITY', '480p')
    if os.getenv('LOCAL') == 'true':
        selected = select_quality({preferred: {}}, preferred, old)
    else:
        result = subprocess.run(['streamlink', '--no-config', '--json', f'https://www.twitch.tv/videos/{os.environ["VOD_ID"]}'], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError('Streamlink could not fetch renditions; availability was not changed')
        streams = json.loads(result.stdout).get('streams', {})
        selected = select_quality(streams, preferred, old)
    output('quality', selected.removesuffix('60'))
    output('video_fps', '60' if selected.endswith('60') else '30')
    output('sfde_profile', profile)


def fail_queued() -> None:
    """Release only this dispatch's queued work; running/completed chunks retain ownership."""
    ids = input_chunk_ids()
    if not ids:
        return
    api('fail-queued', body={'ids': ids, 'queued_at': os.getenv('QUEUED_AT'), 'error': 'Workflow preparation failed'}, method='POST')


def fail_chunk() -> None:
    chunk_id = str(UUID(os.environ['CHUNK_ID']))
    api('fail-queued', body={'ids': [chunk_id], 'queued_at': os.getenv('QUEUED_AT'), 'error': 'Runner failed before claiming chunk'}, method='POST')


def summarize() -> None:
    source = Path('output') / f'detections_{os.environ["CHUNK_ID"]}.json'
    if not source.exists():
        return
    summary = json.loads(source.read_text())
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as destination:
        destination.write(f"### Chunk {summary['chunk_id']}\n\n{summary['frames_processed']} frames; {summary['matchups_found']} matchups.\n\n")
        destination.write('| Second | Username | Confidence | Rank | Day |\n|---|---|---|---|---|\n')
        for item in summary['detections']:
            username = str(item['username']).replace('|', '\\|').replace('\n', ' ')
            destination.write(f"| {item['timestamp']} | {username} | {item['confidence']:.0%} | {item['rank']} | {item.get('igd') or ''} |\n")


def main() -> None:
    commands = {'prepare': prepare, 'fail-queued': fail_queued, 'summary': summarize, 'fail-chunk': fail_chunk}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise SystemExit('Usage: vod_workflow.py prepare|fail-queued|fail-chunk|summary')
    commands[sys.argv[1]]()


if __name__ == '__main__':
    main()
