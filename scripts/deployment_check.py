#!/usr/bin/env python3
"""Validate resource isolation and the invoking branch before remote deployment."""
import argparse
import json
import os
from pathlib import Path
from urllib.parse import urlsplit
from uuid import UUID


ROOT = Path(__file__).resolve().parents[1]
BRANCHES = {
    'dev': 'refs/heads/dev',
    'production': 'refs/heads/main',
    'validation': 'refs/heads/codex/cloudflare-validation',
}
ZERO_UUID = '00000000-0000-0000-0000-000000000000'


def read_jsonc(path):
    """Accept Wrangler comments/trailing commas without modifying string contents."""
    source = Path(path).read_text()
    tokens = []
    index = 0
    decoder = json.JSONDecoder()
    while index < len(source):
        if source[index] == '"':
            _, end = decoder.raw_decode(source, index)
            tokens.append(source[index:end])
            index = end
        elif source.startswith('//', index):
            end = source.find('\n', index)
            tokens.append(' ')
            index = len(source) if end < 0 else end
        elif source.startswith('/*', index):
            end = source.find('*/', index + 2)
            if end < 0:
                raise ValueError(f'Unclosed JSONC comment in {path}')
            tokens.append(' ')
            index = end + 2
        elif source[index].isspace():
            tokens.append(source[index])
            index += 1
        else:
            tokens.append(source[index])
            index += 1
    cleaned = ''.join(token for i, token in enumerate(tokens)
                      if token != ',' or next((t for t in tokens[i + 1:] if not t.isspace()), None) not in ('}', ']'))
    return json.loads(cleaned)


def resource_names(config):
    queues = config.get('queues', {})
    return {
        'Worker name': {config['name']},
        'database': {str(UUID(d['database_id'])) for d in config.get('d1_databases', []) if d.get('database_id') != ZERO_UUID},
        'database name': {d['database_name'] for d in config.get('d1_databases', [])},
        'storage bucket': {b['bucket_name'] for b in config.get('r2_buckets', [])},
        'queue': {q[key] for section in ('producers', 'consumers') for q in queues.get(section, [])
                  for key in ('queue', 'dead_letter_queue') if key in q},
    }


def validate(target, root=ROOT, ref=None):
    if target not in BRANCHES:
        raise ValueError('Target must be dev, production or validation')
    if ref is not None and ref != BRANCHES[target]:
        raise ValueError(f'{target} deployment requires branch {BRANCHES[target]}')
    config = read_jsonc(Path(root) / f'wrangler.{target}.jsonc')
    if config['vars']['ENVIRONMENT'] != target:
        raise ValueError('Environment mismatch')
    if config['name'] != f'bazaarghost-{target}':
        raise ValueError('Worker name must match the target environment')
    public_url = config['vars']['PUBLIC_URL']
    url = urlsplit(public_url)
    if ('REPLACE_ME' in public_url or url.scheme != 'https' or not url.hostname
            or url.username or url.password or url.query or url.fragment or url.path not in ('', '/')):
        raise ValueError('Set the public HTTPS Worker origin without credentials, path or query')
    databases = config.get('d1_databases', [])
    if len(databases) != 1 or databases[0].get('binding') != 'DB':
        raise ValueError('Configure exactly one D1 database bound as DB')
    if databases[0].get('database_name') != f'bazaarghost-{target}':
        raise ValueError('Database name must match the target environment')
    try:
        database_id = str(UUID(databases[0].get('database_id', '')))
    except ValueError as error:
        raise ValueError('Set the provisioned D1 database UUID') from error
    if database_id == ZERO_UUID:
        raise ValueError('Set the provisioned D1 database ID')
    buckets = config.get('r2_buckets', [])
    if len(buckets) != 2 or {b.get('binding') for b in buckets} != {'DETECTIONS', 'LOGS'}:
        raise ValueError('Configure separate DETECTIONS and LOGS buckets')
    if len({b['bucket_name'] for b in buckets}) != 2 or any('local' in b['bucket_name'] for b in buckets):
        raise ValueError('Deployment buckets must be distinct and cannot be local')
    if not config.get('workers_dev') and not config.get('routes'):
        raise ValueError('Configure a route/custom domain or enable workers_dev')

    if target == 'validation':
        # The validation Worker may never take over an existing site's route.
        if config.get('routes') or config.get('route') or not config.get('workers_dev'):
            raise ValueError('Validation uses only its dedicated workers.dev hostname')
        if not url.hostname.startswith('bazaarghost-validation.') or not url.hostname.endswith('.workers.dev'):
            raise ValueError('Validation URL must be its dedicated workers.dev hostname')
        expected_buckets = {'DETECTIONS': 'bazaarghost-validation-detections', 'LOGS': 'bazaarghost-validation-logs'}
        if {b['binding']: b['bucket_name'] for b in buckets} != expected_buckets:
            raise ValueError('Validation bucket names must use its isolated namespace')
        producers = config.get('queues', {}).get('producers', [])
        consumers = config.get('queues', {}).get('consumers', [])
        if (len(producers) != 1 or producers[0].get('binding') != 'JOBS'
                or producers[0].get('queue') != 'bazaarghost-validation-jobs'
                or len(consumers) != 1 or consumers[0].get('queue') != 'bazaarghost-validation-jobs'
                or consumers[0].get('dead_letter_queue') != 'bazaarghost-validation-dlq'):
            raise ValueError('Validation queues must use its isolated namespace')

    resources = resource_names(config)
    for other in BRANCHES:
        if other == target:
            continue
        path = Path(root) / f'wrangler.{other}.jsonc'
        if not path.exists():
            raise ValueError(f'Missing comparison configuration: {path.name}')
        for kind, names in resource_names(read_jsonc(path)).items():
            if resources[kind] & names:
                raise ValueError(f'{target} and {other} must not share a {kind}')
    return config


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=BRANCHES)
    parser.add_argument('--ref', default=os.environ.get('GITHUB_REF'))
    args = parser.parse_args()
    validate(args.target, ref=args.ref)
    print(f'Deployment configuration validated: {args.target}')
