#!/usr/bin/env python3
"""Read-only, paginated PostgREST export to one JSONL file per application table.

Usage: SUPABASE_URL=... SUPABASE_SECRET_KEY=... python scripts/migration/export_supabase.py .ignore/export
Run after pausing cataloging/processing and draining active chunks for a consistent snapshot.
This script never alters the source and never copies storage objects.
"""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError

TABLES = ('sfde_profiles', 'streamers', 'vods', 'chunks', 'detections',
          'notification_subscriptions', 'server_channels', 'processing_config', 'cataloger_runs')
KEYS = {'server_channels': 'guild_id', 'processing_config': 'key', 'notification_subscriptions': 'discord_user_id,username_lower'}


def export(destination):
    destination.mkdir(parents=True, exist_ok=False)
    root, secret = os.environ['SUPABASE_URL'].rstrip('/'), os.environ['SUPABASE_SECRET_KEY']
    counts = {}
    for table in TABLES:
        key, cursor, count = KEYS.get(table, 'id'), None, 0
        with (destination / f'{table}.jsonl').open('x') as output:
            while True:
                params = {'select': '*', 'order': key, 'limit': '1000'}
                if table == 'notification_subscriptions':
                    params['offset'] = str(count)
                elif cursor is not None:
                    params[key] = 'gt.' + str(cursor)
                request = Request(root + '/rest/v1/' + table + '?' + urlencode(params), headers={
                    'apikey': secret, 'Authorization': 'Bearer ' + secret})
                try:
                    with urlopen(request, timeout=60) as response:
                        rows = json.load(response)
                except HTTPError as error:
                    if table != 'sfde_profiles' or error.code != 404:
                        raise
                    # Production may still use the pre-rename table. This remains read-only.
                    request.full_url = request.full_url.replace('/sfde_profiles?', '/sfot_profiles?')
                    with urlopen(request, timeout=60) as response:
                        rows = json.load(response)
                if not isinstance(rows, list):
                    raise ValueError(f'Invalid export response for {table}')
                for row in rows:
                    output.write(json.dumps(row, ensure_ascii=False) + '\n')
                    count += 1
                if len(rows) < 1000:
                    break
                if table == 'notification_subscriptions':
                    continue
                if rows[-1][key] == cursor:
                    raise ValueError('Export cursor did not advance')
                cursor = rows[-1][key]
        counts[table] = count
        print(f'{table}: {count} rows')
    (destination / 'manifest.json').write_text(json.dumps(counts, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    export(parser.parse_args().destination)
