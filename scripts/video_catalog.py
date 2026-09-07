"""Shared platform catalog persistence and revision boundaries."""

from typing import Any, Dict

from vod_workflow import api


def save_video(video: Dict[str, Any], account: Dict[str, Any],
               explicit_ranges: bool = False) -> Dict[str, Any]:
    """Idempotently register media without silently rewriting processed timelines."""
    existing = api('vods', {'source': f'eq.{video["source"]}', 'source_id': f'eq.{video["source_id"]}'})
    values = {**video, 'platform_account_id': account['id'], 'streamer_id': account.get('streamer_id')}
    if existing:
        current = existing[0]
        if current.get('platform_account_id') not in (None, account['id']):
            raise ValueError('Video account identity changed')
        if current['duration_seconds'] != values['duration_seconds']:
            chunks = api('chunks', {'vod_id': f'eq.{current["id"]}', 'select': 'id', 'limit': '1'})
            if chunks:
                raise ValueError('Video duration changed; inspect and explicitly reprocess this revision')
        # Preserve operator overrides during routine recataloging.
        for field in ('recorded_at', 'template_version'):
            if values[field] in (None, 'auto'):
                values.pop(field)
        if not explicit_ranges:
            values.pop('bazaar_chapters')
        elif current.get('bazaar_chapters') != values['bazaar_chapters']:
            chunks = api('chunks', {'vod_id': f'eq.{current["id"]}', 'select': 'id', 'limit': '1'})
            if chunks:
                raise ValueError('Gameplay ranges changed; inspect and explicitly reprocess this revision')
        result = api('vods', {'id': f'eq.{current["id"]}'}, values, 'PATCH')[0]
    else:
        result = api('vods', body=values, method='POST')[0]
    # Enabling an already-cataloged account/video must also create any missing work.
    api('rpc/create_missing_chunks_for_vod', body={'p_vod_id': result['id']}, method='POST')
    api('chunks', {'vod_id': f'eq.{result["id"]}', 'status': 'eq.pending'}, {'priority': -10}, 'PATCH')
    return result
