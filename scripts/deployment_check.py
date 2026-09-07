#!/usr/bin/env python3
"""Validate the concrete target config before a manually enabled deployment."""
import json
from pathlib import Path
import sys


def validate(target):
    if target not in ('dev', 'production'):
        raise ValueError('Target must be dev or production')
    config = json.loads(Path(f'wrangler.{target}.jsonc').read_text())
    if config['vars']['ENVIRONMENT'] != target:
        raise ValueError('Environment mismatch')
    if 'REPLACE_ME' in config['vars']['PUBLIC_URL'] or not config['vars']['PUBLIC_URL'].startswith('https://'):
        raise ValueError('Set the public HTTPS Worker URL')
    if any(db['database_id'] == '00000000-0000-0000-0000-000000000000' for db in config['d1_databases']):
        raise ValueError('Set the provisioned D1 database ID')
    if any('local' in b['bucket_name'] for b in config['r2_buckets']):
        raise ValueError('Local bucket in deployment config')
    if not config.get('workers_dev') and not config.get('routes'):
        raise ValueError('Configure a route/custom domain or enable workers_dev')
    other = 'production' if target == 'dev' else 'dev'
    other_config = json.loads(Path(f'wrangler.{other}.jsonc').read_text())
    if {d['database_id'] for d in config['d1_databases']} & {d['database_id'] for d in other_config['d1_databases']}:
        raise ValueError('Dev and production must not share a database')
    if {b['bucket_name'] for b in config['r2_buckets']} & {b['bucket_name'] for b in other_config['r2_buckets']}:
        raise ValueError('Dev and production must not share storage buckets')
    return config


if __name__ == '__main__':
    validate(sys.argv[1])
    print('Deployment configuration validated')
