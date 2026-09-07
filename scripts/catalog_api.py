"""Narrow catalog API: media runners never receive database or WebSub secrets."""

import json
import os
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request

from backend_environment import open_backend, selected_environment, verify_backend

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sfde' / 'src'))


def fence(job=None):
    return {'job_id': job['id'], 'lease_token': job['lease_token']} if job is not None else {}


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
