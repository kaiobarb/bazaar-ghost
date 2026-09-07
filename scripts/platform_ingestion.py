#!/usr/bin/env python3
"""Enroll creators and drain durable discovery/poll/archive jobs (explicit environment only)."""

import argparse
from datetime import datetime, timedelta, timezone
import json
import os
import time
from typing import Any, Dict, Optional
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

from vod_workflow import api
from catalog_youtube import ensure_account as youtube_account, normalize_video, channel_page
from catalog_bilibili import ensure_account as bilibili_account, normalize_part
from media_source import youtube_metadata
from bilibili_source import video_metadata
from platform_discovery import account_page, bazaar_title, bilibili_api, discover
from video_catalog import save_video


def rpc(name: str, **values: Any) -> Any:
    """Invoke a service-only control-plane operation."""
    return api('rpc/' + name, body=values, method='POST')


def enqueue(source: str, kind: str, identity: str, account_id: Optional[str] = None) -> None:
    """Persist work before advancing discovery progress."""
    rpc('enqueue_platform_ingestion', p_source=source, p_kind=kind,
        p_source_id=identity, p_account_id=account_id)


def enroll(source: str, identity: str, profile_id: Optional[int] = None,
           streamer_id: Optional[int] = None) -> Dict[str, Any]:
    """Explicit enrollment enables an account; discovery preserves operator disables."""
    if source == 'youtube':
        channel = 'https://www.youtube.com/' + identity if identity.startswith('@') else identity
        page = channel_page(channel, 1, 1, 'videos')
        if page.get('tab_absent'):
            page = channel_page(channel, 1, 1, 'streams')
        return youtube_account(page.get('channel_id') or page['id'],
                               page.get('channel') or page.get('title') or identity,
                               True, streamer_id, profile_id)
    if not identity.isascii() or not identity.isdecimal() or int(identity) <= 0:
        raise ValueError('Bilibili enrollment expects the uploader UID from space.bilibili.com/<UID>')
    owner = bilibili_api('/x/web-interface/card', {'mid': identity})['card']
    if str(owner['mid']) != identity:
        raise ValueError('Uploader identity mismatch')
    return bilibili_account(owner, True, profile_id, streamer_id)


def renew_subscription(account: Dict[str, Any]) -> None:
    """Renew signed WebSub; callbacks are served by the Supabase Edge Function."""
    base = os.environ['SUPABASE_URL'].rstrip('/')
    parsed = urlparse(base)
    if parsed.scheme != 'https' or parsed.hostname in ('localhost', '127.0.0.1'):
        return  # Local tests have no public callback. Polling remains fully usable.
    rows = api('youtube_websub_subscriptions', {'account_id': 'eq.' + account['id']})
    if not rows:
        rows = api('youtube_websub_subscriptions', body={'account_id': account['id']}, method='POST')
    subscription = rows[0]
    now = datetime.now(timezone.utc)
    expiry = subscription.get('lease_expires_at')
    requested = subscription.get('requested_at')
    if expiry and datetime.fromisoformat(expiry) > now + timedelta(hours=12):
        return
    if requested and datetime.fromisoformat(requested) > now - timedelta(hours=1):
        return  # Await asynchronous verification; don't issue overlapping requests.
    api('youtube_websub_subscriptions', {'account_id': 'eq.' + account['id']},
        {'requested_at': now.isoformat(), 'last_error': None}, 'PATCH')
    callback = base + '/functions/v1/youtube-webhook?' + urlencode({
        'account': account['id'], 'token': subscription['callback_token'],
    })
    payload = urlencode({
        'hub.mode': 'subscribe', 'hub.callback': callback,
        'hub.topic': 'https://www.youtube.com/feeds/videos.xml?channel_id=' + account['source_id'],
        'hub.verify': 'async', 'hub.lease_seconds': '864000', 'hub.secret': subscription['secret'],
    }).encode()
    try:
        with urlopen(Request('https://pubsubhubbub.appspot.com/subscribe', data=payload,
                             headers={'Content-Type': 'application/x-www-form-urlencoded'}), timeout=30) as response:
            if response.status not in (202, 204):
                raise RuntimeError('Subscription request not accepted')
    except Exception as error:
        api('youtube_websub_subscriptions', {'account_id': 'eq.' + account['id']},
            {'last_error': type(error).__name__ + ': subscription request failed'}, 'PATCH')
        # Never block polling because a subscription/hub is unavailable.


def poll_account(job: Dict[str, Any]) -> Dict[str, Any]:
    """Catch up across bounded pages to the previous head, retaining unfinished work."""
    source = job['source']
    account = api('platform_accounts', {'id': 'eq.' + job['account_id']})[0]
    state = dict(job['state'])
    errors = []
    catching_up = False
    for tab in (('videos', 'streams') if source == 'youtube' else ('videos',)):
        cursor = dict(state.get(tab, {}))
        start = cursor.get('start', 1)
        try:
            ids = account_page(source, account['source_id'], tab, start)
            for identity in ids:
                enqueue(source, 'video', identity, account['id'])
            head = cursor.get('scan_head') or (ids[0] if ids else cursor.get('head'))
            previous_head = cursor.get('head')
            if previous_head and previous_head not in ids and len(ids) == 20:
                state[tab] = {'head': previous_head, 'scan_head': head, 'start': start + len(ids)}
                catching_up = True
            else:
                state[tab] = {'head': head, 'start': 1}
        except Exception as error:
            errors.append(f'{tab}: {type(error).__name__}; public catalog unavailable')
    if source == 'youtube':
        try:
            renew_subscription(account)
        except Exception as error:
            errors.append(f'websub: {type(error).__name__}; subscription persistence failed')
    delay = 900
    if errors:
        delay *= 2 ** min(max(job.get('attempts', 1) - 1, 0), 4)
    if catching_up:
        delay = 60
    return {'status': 'waiting', 'delay': delay,
            'state': state, 'error': '; '.join(errors) or None}


def verified_account(source: str, metadata: Dict[str, Any], job: Dict[str, Any]) -> Dict[str, Any]:
    """Validate the candidate's actual owner and preserve existing processing settings."""
    identity = metadata['channel_id'] if source == 'youtube' else str(metadata['owner']['mid'])
    rows = api('platform_accounts', {'source': 'eq.' + source, 'source_id': 'eq.' + identity})
    if job.get('account_id') and (not rows or rows[0]['id'] != job['account_id']):
        raise ValueError('Candidate owner does not match the enrolled account')
    if rows:
        return rows[0]
    # Like Twitch discovery, new game-matching creators are enabled. An operator disable wins thereafter.
    if source == 'youtube':
        return youtube_account(identity, metadata.get('channel') or identity, True)
    return bilibili_account(metadata['owner'], True, None, None)


def ingest_video(job: Dict[str, Any]) -> Dict[str, Any]:
    """Wait for final recordings; ingest every published Bilibili part idempotently."""
    source = job['source']
    metadata = youtube_metadata(job['source_id']) if source == 'youtube' else video_metadata(job['source_id'])
    if source == 'youtube':
        evidence = bazaar_title(metadata.get('title') or '') or any(
            str(tag).lower() in ('the bazaar', 'thebazaar') for tag in metadata.get('tags') or [])
    else:
        evidence = bazaar_title(metadata.get('title') or '') or any(
            bazaar_title(p.get('part') or '') for p in metadata['pages'])
    if not evidence:
        return {'status': 'skipped', 'state': {'reason': 'No Bazaar title/tag evidence'}}
    account = verified_account(source, metadata, job)
    api('platform_ingestion_jobs', {'id': 'eq.' + job['id'], 'lease_token': 'eq.' + job['lease_token']},
        {'account_id': account['id']}, 'PATCH')
    if not account['processing_enabled']:
        return {'status': 'skipped', 'state': {'reason': 'Account disabled'}}
    if source == 'youtube' and (metadata.get('live_status') in ('is_live', 'is_upcoming', 'post_live') or metadata.get('is_live')):
        return {'status': 'waiting', 'delay': 900, 'state': {'archive_state': metadata.get('live_status')}}
    if source == 'youtube':
        videos = [normalize_video(metadata)]
        continuation = None
    else:
        seen = set(job['state'].get('seen_cids', []))
        remaining = [p for p in metadata['pages'] if str(p['cid']) not in seen]
        selected = remaining[:20]
        videos = [normalize_part(metadata, str(p['cid'])) for p in selected if
                  bazaar_title(metadata.get('title') or '') or bazaar_title(p.get('part') or '')]
        continuation = sorted(seen | {str(p['cid']) for p in selected}) if len(remaining) > len(selected) else None
    ids = [save_video(video, account)['id'] for video in videos]
    return {'status': 'waiting' if continuation is not None else 'completed', 'delay': 60,
            'state': {'seen_cids': continuation} if continuation is not None else {}, 'vod_ids': ids}


def handle_job(job: Dict[str, Any]) -> Dict[str, Any]:
    """Process one lease. Transport/media failures retry without losing the candidate."""
    if job['kind'] == 'account':
        return poll_account(job)
    if job['kind'] == 'discovery':
        ids = discover(job['source'])
        for identity in ids:
            enqueue(job['source'], 'video', identity)
        return {'status': 'waiting', 'delay': 21600, 'state': {'candidates': len(ids)}}
    return ingest_video(job)


def dispatch_pending(limit: int, dry_run: bool = False) -> int:
    """Feed due work into the existing atomic SFDE dispatcher, including earlier retries."""
    rows = rpc('get_platform_ingestion_dispatches', p_limit=limit)
    base = os.environ['SUPABASE_URL'].rstrip('/')
    key = os.environ['SUPABASE_SECRET_KEY']
    for row in rows:
        request = Request(base + '/functions/v1/process-vod', data=json.dumps({
            'vod_id': row['vod_id'], 'expected_environment': 'dev', 'dry_run': dry_run,
        }).encode(), headers={'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        with urlopen(request, timeout=60) as response:
            if not json.load(response).get('success'):
                raise RuntimeError('Processing dispatch failed')
    return len(rows)


def run(limit: int, seconds: int, discovery: bool = True, dispatch: bool = False) -> Dict[str, Any]:
    """Drain bounded work and report partial failures while preserving durable retries."""
    deadline = time.monotonic() + seconds
    summary = {'jobs': 0, 'errors': 0, 'cataloged': 0, 'dispatched': 0}
    while summary['jobs'] < limit and time.monotonic() < deadline:
        jobs = rpc('claim_platform_ingestion', p_include_discovery=discovery)
        if not jobs:
            break
        job = jobs[0]
        try:
            result = handle_job(job)
        except Exception as error:
            # Error classes suffice for health; no signed URLs, callback tokens, or HTTP bodies in logs.
            result = {'status': 'waiting', 'delay': min(21600, 300 * 2 ** min(job['attempts'], 6)),
                      'state': job['state'], 'error': type(error).__name__ + ': ingestion failed; retry scheduled'}
        finished = rpc('finish_platform_ingestion', p_id=job['id'], p_token=job['lease_token'],
                       p_status=result['status'], p_delay_seconds=result.get('delay', 900),
                       p_error=result.get('error'), p_state=result.get('state', {}))
        summary['jobs'] += 1
        summary['errors'] += int(bool(result.get('error')) or not finished)
        summary['cataloged'] += len(result.get('vod_ids', []))
        print(json.dumps({'job_id': job['id'], 'source': job['source'], 'kind': job['kind'],
                          'status': result['status'], 'error': result.get('error'), 'lease_finished': finished}), flush=True)
    if dispatch:
        summary['dispatched'] = dispatch_pending(3)
    # Delivery receipts are transient; repeating an older body remains safe through catalog idempotency.
    cutoff = (datetime.now(timezone.utc) - timedelta(days=30)).isoformat()
    api('youtube_websub_deliveries', {'received_at': 'lt.' + cutoff}, method='DELETE')
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    add = commands.add_parser('enroll')
    add.add_argument('--source', required=True, choices=('youtube', 'bilibili'))
    add.add_argument('--identity', required=True, help='YouTube UC ID/@handle/URL, or Bilibili uploader UID')
    add.add_argument('--profile-id', type=int)
    add.add_argument('--streamer-id', type=int)
    drain = commands.add_parser('run')
    drain.add_argument('--limit', type=int, default=30)
    drain.add_argument('--seconds', type=int, default=1200)
    drain.add_argument('--no-discovery', action='store_true')
    drain.add_argument('--dispatch', action='store_true', help='Dispatch up to three due videos through the dev Edge Function')
    args = parser.parse_args()
    if args.command == 'enroll':
        account = enroll(args.source, args.identity, args.profile_id, args.streamer_id)
        print(json.dumps({'account_id': account['id'], 'source': account['source'], 'source_id': account['source_id']}))
    else:
        if not 1 <= args.limit <= 100 or not 30 <= args.seconds <= 1200:
            parser.error('Use 1-100 jobs and a 30-1200 second budget')
        summary = run(args.limit, args.seconds, not args.no_discovery, args.dispatch)
        print(json.dumps(summary))
        if summary['errors']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
