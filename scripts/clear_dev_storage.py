#!/usr/bin/env python3
"""Request the dev-only R2 sweep. The Worker independently enforces its environment."""
import json
import os
from urllib.request import Request, urlopen


def main():
    url = os.environ['BAZAARGHOST_API_URL'].rstrip('/')
    with urlopen(url + '/health', timeout=30) as response:
        health = json.load(response)
    if health.get('environment') != 'dev':
        raise SystemExit('Refusing to clear storage outside dev')
    request = Request(url + '/api/admin/clear-dev-storage', method='POST', data=b'{}', headers={
        'Authorization': 'Bearer ' + os.environ['BAZAARGHOST_ADMIN_KEY'], 'Content-Type': 'application/json'})
    with urlopen(request, timeout=60) as response:
        print(json.load(response))


if __name__ == '__main__':
    main()
