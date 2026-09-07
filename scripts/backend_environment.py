"""Verify the explicitly selected backend before a workflow sends credentials."""

from functools import lru_cache
import json
import os
from urllib.parse import urlparse
from urllib.request import HTTPRedirectHandler, Request, build_opener


BRANCHES = {'validation': 'codex/cloudflare-validation', 'dev': 'dev', 'production': 'main'}
USER_AGENT = 'BazaarGhost/1.0 (+https://github.com/liftaris/bazaar-ghost)'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError('Backend redirects are not permitted')


def open_backend(request, timeout=30):
    """A backend credential must never follow a redirect to another origin."""
    # Cloudflare rejects urllib's generic default signature on the hosted endpoint.
    request.add_header('User-Agent', USER_AGENT)
    return build_opener(NoRedirect).open(request, timeout=timeout)


def selected_environment():
    base = os.environ['BAZAARGHOST_API_URL'].rstrip('/')
    parsed = urlparse(base)
    local = parsed.hostname in ('localhost', '127.0.0.1', '::1')
    if parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path:
        raise ValueError('BAZAARGHOST_API_URL must be a backend origin')
    if not parsed.hostname or parsed.scheme not in (('http', 'https') if local else ('https',)):
        raise ValueError('Remote backends require HTTPS')
    environment = os.getenv('ENVIRONMENT') or ('local' if local else '')
    if environment not in {'local', *BRANCHES} or (environment == 'local') != local:
        raise ValueError('Select a matching ENVIRONMENT and backend origin')
    if os.getenv('GITHUB_ACTIONS') == 'true':
        if os.getenv('GITHUB_REF') != 'refs/heads/' + BRANCHES.get(environment, ''):
            raise ValueError('GitHub branch does not match the selected backend environment')
    return base, environment


@lru_cache(maxsize=8)
def _health(base, environment):
    with open_backend(Request(base + '/health'), timeout=15) as response:
        payload = response.read(4097)
    if len(payload) > 4096:
        raise ValueError('Unexpected backend health response')
    health = json.loads(payload)
    if health.get('ok') is not True or health.get('environment') != environment:
        raise ValueError('Backend environment check failed')
    return environment


def verify_backend():
    return _health(*selected_environment())


if __name__ == '__main__':
    print(json.dumps({'verified_environment': verify_backend()}))
