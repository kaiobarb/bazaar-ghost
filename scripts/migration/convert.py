#!/usr/bin/env python3
"""Validate a JSONL snapshot offline and emit a D1 SQLite SQL import.

Creates an intermediate SQLite database and imports in dependency order. Constraint or
foreign-key failures stop conversion; nothing is silently discarded. Imported notifications
are marked delivered to prevent replaying history. Storage paths remain unchanged.
"""
import argparse
import json
from pathlib import Path
import re
import sqlite3
import unicodedata

TABLES = ('sfde_profiles', 'streamers', 'vods', 'chunks', 'detections',
          'notification_subscriptions', 'server_channels', 'processing_config', 'cataloger_runs')
ROOT = Path(__file__).resolve().parents[2]


def trigrams(value):
    words, word = [], ''
    for char in value.lower():
        if unicodedata.category(char)[0] in ('L', 'N'):
            word += char
        elif word:
            words.append(word)
            word = ''
    if word:
        words.append(word)
    return sorted({('  ' + word + ' ')[i:i + 3] for word in words for i in range(len(word) + 1)})


def convert(source, destination):
    if destination.exists():
        raise ValueError('Destination already exists; choose a new directory')
    destination.mkdir(parents=True)
    db = sqlite3.connect(destination / 'snapshot.sqlite')
    db.execute('PRAGMA foreign_keys=ON')
    db.executescript((ROOT / 'worker/migrations/0001_backend.sql').read_text())
    counts, unknown, vod_statuses = {}, {}, []
    for table in TABLES:
        columns = {r[1] for r in db.execute(f'PRAGMA table_info({table})')}
        count, extra = 0, set()
        with (source / f'{table}.jsonl').open() as rows:
            for line in rows:
                record = json.loads(line)
                if table == 'streamers' and 'sfot_profile_id' in record:
                    if 'sfde_profile_id' in record:
                        raise ValueError('Both legacy and current profile references exist')
                    record['sfde_profile_id'] = record.pop('sfot_profile_id')
                extra.update(set(record) - columns)
                row = {k: v for k, v in record.items() if k in columns}
                if table == 'vods':
                    vod_statuses.append((row.get('status', 'pending'), row['id']))
                if table == 'chunks':
                    if row.get('status') in ('processing', 'queued'):
                        raise ValueError('Snapshot contains active chunks. Pause and drain processing before export.')
                    row['claim_token'], row['lease_expires_at'] = None, None
                if table == 'detections':
                    name = row['username'].lower()
                    grams = trigrams(name)
                    db.execute('INSERT OR IGNORE INTO search_names VALUES(?,?)', (name, len(grams)))
                    db.executemany('INSERT OR IGNORE INTO search_grams VALUES(?,?)', ((g, name) for g in grams))
                    row['username_lower'] = name
                if table == 'notification_subscriptions':
                    row['username_lower'] = row['username'].lower()
                row = {k: json.dumps(v, ensure_ascii=False) if isinstance(v, (list, dict)) else int(v) if isinstance(v, bool) else v for k, v in row.items()}
                names = ','.join('"' + k + '"' for k in row)
                try:
                    db.execute(f'INSERT INTO {table}({names}) VALUES({",".join("?" for _ in row)})', list(row.values()))
                except sqlite3.IntegrityError as error:
                    raise ValueError(f'{table} row {record.get("id")}: {error}') from error
                count += 1
        counts[table] = count
        if extra:
            unknown[table] = sorted(extra)
    # New D1-only columns are intentional. Unmapped source columns require explicit review.
    if unknown:
        (destination / 'unmapped-columns.json').write_text(json.dumps(unknown, indent=2))
        raise ValueError('Unmapped source columns; see unmapped-columns.json. Review before importing.')
    db.executemany('UPDATE vods SET status=? WHERE id=?', vod_statuses)
    db.execute("UPDATE notification_outbox SET sent_at=strftime('%Y-%m-%dT%H:%M:%fZ','now')")
    problems = db.execute('PRAGMA foreign_key_check').fetchall()
    if problems:
        raise ValueError(f'Foreign-key errors: {problems[:10]}')
    db.commit()
    # Insert existing data before creating triggers, preventing historical notification replay.
    triggers = db.execute("SELECT name,sql FROM sqlite_master WHERE type='trigger'").fetchall()
    with (destination / 'import.sql').open('w') as output:
        output.write('PRAGMA defer_foreign_keys=ON;\n')
        for name, _ in triggers:
            output.write(f'DROP TRIGGER IF EXISTS {name};\n')
        ordered = ('sfde_profiles', 'streamers', 'vods', 'chunks', 'search_names', 'search_grams',
                   'detections', 'notification_subscriptions', 'server_channels', 'processing_config',
                   'cataloger_runs', 'notification_outbox', 'notification_deliveries', 'webhook_events', 'chat_mentions')
        for table in ordered:
            columns = [r[1] for r in db.execute(f'PRAGMA table_info({table})')]
            quoted = ','.join(f'quote("{column}")' for column in columns)
            names = ','.join(f'"{column}"' for column in columns)
            for values in db.execute(f'SELECT {quoted} FROM {table}'):
                output.write(f'INSERT INTO {table}({names}) VALUES({",".join(values)});\n')
        for _, sql in triggers:
            output.write(sql + ';\n')
    # Split at complete SQL statements, keeping every part small enough for CLI import.
    part = None
    size, number = 0, 0
    pending = ''
    with (destination / 'import.sql').open() as sql:
        for line in sql:
            pending += line
            if not sqlite3.complete_statement(pending):
                continue
            if part is None or size + len(pending.encode()) > 4_000_000:
                if part:
                    part.close()
                number += 1
                part = (destination / f'import-{number:04}.sql').open('w')
                size = 0
            part.write(pending)
            size += len(pending.encode())
            pending = ''
    if pending.strip():
        raise ValueError('Incomplete SQL statement in export')
    if part:
        part.close()
    (destination / 'manifest.json').write_text(json.dumps(counts, indent=2) + '\n')
    print(json.dumps(counts, indent=2))
    db.close()
    return counts


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    convert(args.source, args.destination)
