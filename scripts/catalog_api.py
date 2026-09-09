"""Narrow catalog API: media runners never receive database or WebSub secrets."""

import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request
from uuid import UUID

from backend_environment import open_backend, selected_environment, verify_backend

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sfde' / 'src'))


def fence(job=None):
    return {'job_id': job['id'], 'lease_token': job['lease_token']} if job is not None else {}


def runner_context():
    """A dispatch ticket is an identifier; the catalog capability authenticates it."""
    ticket = os.getenv('INGEST_DISPATCH_TICKET')
    if not ticket:
        return {}
    context = {'ticket_id': str(UUID(ticket)), 'run_id': os.getenv('GITHUB_RUN_ID', ''),
               'run_attempt': os.getenv('GITHUB_RUN_ATTEMPT', '')}
    if any(not re.fullmatch(r'[1-9][0-9]{0,24}', context[key]) for key in ('run_id', 'run_attempt')):
        raise ValueError('Automatic ingestion requires a GitHub run identity')
    if os.getenv('SOURCE', 'none') != 'none' or os.getenv('IDENTITY') or os.getenv('DISCOVERY', 'false') != 'false':
        raise ValueError('Automatic ingestion may only drain existing work')
    context['expected_environment'] = verify_backend()
    return context


def api(path, params=None, body=None, method='GET'):
    verify_backend()
    base, _ = selected_environment()
    url = base + '/api/catalog/' + path
    if params:
        url += '?' + urlencode(params)
    request = Request(url, method=method, data=None if body is None else json.dumps(body).encode(), headers={
        'Authorization': 'Bearer ' + os.environ['BAZAARGHOST_CATALOG_KEY'],
        'Content-Type': 'application/json',
    })
    try:
        with open_backend(request, timeout=60) as response:
            data = response.read(2_000_001)
    except HTTPError as error:
        raise RuntimeError(f'Catalog {method} {path.split("?")[0]} failed: HTTP {error.code}') from None
    if len(data) > 2_000_000:
        raise ValueError('Catalog response exceeded its size limit')
    return json.loads(data) if data else None


def runner_lifecycle(path, body):
    """Retry a lost response under the same identity, never invent a new owner."""
    for attempt in range(3):
        try:
            return api('runner/' + path, body=body, method='POST')
        except (OSError, RuntimeError, ValueError):
            if attempt == 2:
                raise RuntimeError('Ingestion runner lifecycle response unavailable') from None
            time.sleep(2 ** attempt)


def workflow_start():
    verify_backend()
    context = runner_context()
    result = runner_lifecycle('start', context) if context else {'started': True}
    if not isinstance(result, dict) or type(result.get('started')) is not bool:
        raise ValueError('Invalid runner start response')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'proceed={str(result["started"]).lower()}\nautomatic={str(bool(context)).lower()}\n')
    print(json.dumps({'runner_started': result['started'], 'automatic': bool(context)}))
    if not result['started'] and os.getenv('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('This ingestion dispatch was superseded or expired; no provider work was started.\n')


def workflow_finish():
    context = runner_context()
    outcome = os.environ.get('INGEST_OUTCOME')
    if not context or outcome not in ('success', 'failure', 'cancelled'):
        raise ValueError('Expected automatic runner identity and outcome')
    result = runner_lifecycle('finish', {**context, 'outcome': outcome})
    if not isinstance(result, dict) or result.get('finished') is not True:
        raise RuntimeError('Runner finish did not retain dispatch ownership')
    print(json.dumps({'runner_finished': True, 'outcome': outcome}))


if __name__ == '__main__':
    commands = {'runner-start': workflow_start, 'runner-finish': workflow_finish}
    if len(sys.argv) != 2 or sys.argv[1] not in commands:
        raise SystemExit('Usage: catalog_api.py runner-start|runner-finish')
    commands[sys.argv[1]]()
