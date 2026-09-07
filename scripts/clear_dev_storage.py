#!/usr/bin/env python3
"""Request the dev-only R2 sweep. The Worker independently enforces its environment."""
import json
import os
from urllib.request import Request

from backend_environment import open_backend, selected_environment, verify_backend


def main():
    url, environment = selected_environment()
    if environment != 'dev' or verify_backend() != 'dev':
        raise SystemExit('Refusing to clear storage outside dev')
    request = Request(url + '/api/admin/clear-dev-storage', method='POST', data=b'{}', headers={
        'Authorization': 'Bearer ' + os.environ['BAZAARGHOST_ADMIN_KEY'], 'Content-Type': 'application/json'})
    with open_backend(request, timeout=60) as response:
        print(json.load(response))


if __name__ == '__main__':
    main()
