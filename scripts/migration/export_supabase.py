#!/usr/bin/env python3
"""Read-only PostgREST snapshot with explicit table inventory and private artifacts.

Supply SUPABASE_URL and SUPABASE_SECRET_KEY. Pause source cataloging, ingestion and
processing before export; this API cannot supply a cross-table transactional snapshot.
No storage objects, authentication sessions or hosted state are changed by this script.
"""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

if __package__:
    from .snapshot_schema import TABLES, OPTIONAL_TABLES, KEYS, private_json, private_open
else:
    from snapshot_schema import TABLES, OPTIONAL_TABLES, KEYS, private_json, private_open


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP = build_opener(NoRedirect())


def missing_table(error):
    try:
        if error.code != 404:
            return False
        payload = json.loads(error.read(65_536))
    except (ValueError, UnicodeError):
        return False
    finally:
        error.close()
    return isinstance(payload, dict) and payload.get('code') in ('PGRST205', '42P01')


def page(root, secret, table, key, cursor, count):
    keys = key.split(',')
    params = {'select': '*', 'order': ','.join(f'{column}.asc' for column in keys), 'limit': '1000'}
    if len(keys) > 1:
        params['offset'] = str(count)
    elif cursor is not None:
        params[key] = 'gt.' + str(cursor)
    request = Request(root + '/rest/v1/' + table + '?' + urlencode(params), headers={
        'apikey': secret, 'Authorization': 'Bearer ' + secret})
    with HTTP.open(request, timeout=60) as response:
        rows = json.load(response)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise ValueError(f'Invalid export response for {table}')
    return rows


def export(destination):
    root, secret = os.environ['SUPABASE_URL'].rstrip('/'), os.environ['SUPABASE_SECRET_KEY']
    url = urlsplit(root)
    if (url.scheme != 'https' or not url.hostname or url.username or url.password or url.query
            or url.fragment or url.path not in ('', '/')):
        raise ValueError('SUPABASE_URL must be the HTTPS project origin')
    if not secret:
        raise ValueError('SUPABASE_SECRET_KEY is required')
    destination = Path(destination)
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = {'format_version': 2, 'complete': False, 'tables': {},
                'created_at': datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')}
    private_json(destination / 'manifest.json', manifest)
    counts = {}
    for table in TABLES:
        key, cursor, count, source_table = KEYS.get(table, 'id'), None, 0, table
        try:
            rows = page(root, secret, source_table, key, cursor, count)
        except HTTPError as error:
            if not missing_table(error):
                raise ValueError(f'Cannot export {table}: HTTP {error.code}; source state was not changed') from None
            if table == 'sfde_profiles':
                source_table = 'sfot_profiles'
                try:
                    rows = page(root, secret, source_table, key, cursor, count)
                except HTTPError as error:
                    error.close()
                    raise ValueError(f'Export interrupted for {table}: HTTP {error.code}') from None
            elif table in OPTIONAL_TABLES:
                manifest['tables'][table] = {'status': 'absent', 'count': 0, 'reason': 'source table does not exist'}
                counts[table] = 0
                private_json(destination / 'manifest.json', manifest)
                print(f'{table}: absent in source schema')
                continue
            else:
                raise ValueError(f'Required source table {table} is missing') from None
        with private_open(destination / f'{table}.jsonl', 'x') as output:
            while rows:
                keys = key.split(',')
                tail = tuple(rows[-1][column] for column in keys)
                if cursor == (tail if len(keys) > 1 else tail[0]):
                    raise ValueError(f'Export cursor did not advance for {table}')
                for row in rows:
                    output.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
                count += len(rows)
                cursor = tail if len(keys) > 1 else tail[0]
                # Continue through short pages too: a source may enforce a lower page-size cap.
                rows = page(root, secret, source_table, key, cursor, count)
        counts[table] = count
        manifest['tables'][table] = {'status': 'present', 'count': count, 'source_table': source_table}
        private_json(destination / 'manifest.json', manifest)
        print(f'{table}: {count} rows')
    manifest['complete'] = True
    private_json(destination / 'manifest.json', manifest)
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    export(parser.parse_args().destination)
