"""Workflow/backend isolation must hold before sending a processing credential."""

import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from urllib.request import Request

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend_environment as backend
import catalog_api


class EnvironmentTests(unittest.TestCase):
    def setUp(self):
        backend._health.cache_clear()

    def test_remote_requires_an_explicit_environment_and_https(self):
        for values in ({'BAZAARGHOST_API_URL': 'https://worker.example'},
                       {'BAZAARGHOST_API_URL': 'http://worker.example', 'ENVIRONMENT': 'validation'},
                       {'BAZAARGHOST_API_URL': 'https://worker.example/path', 'ENVIRONMENT': 'validation'},
                       {'BAZAARGHOST_API_URL': 'https://user:secret@worker.example', 'ENVIRONMENT': 'validation'}):
            with patch.dict(os.environ, values, clear=True):
                with self.assertRaises(ValueError):
                    backend.selected_environment()

    def test_github_branch_and_environment_are_a_single_pair(self):
        values = {'BAZAARGHOST_API_URL': 'https://worker.example', 'ENVIRONMENT': 'validation',
                  'GITHUB_ACTIONS': 'true', 'GITHUB_REF': 'refs/heads/codex/cloudflare-validation'}
        with patch.dict(os.environ, values, clear=True):
            self.assertEqual(backend.selected_environment()[1], 'validation')
            for ref in ('refs/heads/dev', 'refs/heads/main', 'refs/tags/codex/cloudflare-validation'):
                with patch.dict(os.environ, {'GITHUB_REF': ref}):
                    with self.assertRaisesRegex(ValueError, 'branch'):
                        backend.selected_environment()

    def test_health_is_an_unauthenticated_environment_check(self):
        values = {'BAZAARGHOST_API_URL': 'https://worker.example', 'ENVIRONMENT': 'validation',
                  'BAZAARGHOST_CATALOG_KEY': 'test-key'}
        with patch.dict(os.environ, values, clear=True), patch.object(
                backend, 'open_backend', return_value=io.BytesIO(b'{"ok":true,"environment":"production"}')) as opener:
            with self.assertRaisesRegex(ValueError, 'environment check'):
                catalog_api.api('accounts')
            request = opener.call_args.args[0]
            self.assertEqual(request.full_url, 'https://worker.example/health')
            self.assertIsNone(request.get_header('Authorization'))

    def test_catalog_credential_is_only_sent_after_verified_health(self):
        values = {'BAZAARGHOST_API_URL': 'http://127.0.0.1:8787', 'BAZAARGHOST_CATALOG_KEY': 'local-key'}
        with patch.dict(os.environ, values, clear=True), patch.object(
                backend, 'open_backend', return_value=io.BytesIO(b'{"ok":true,"environment":"local"}')), patch.object(
                catalog_api, 'open_backend', return_value=io.BytesIO(b'[]')) as opener:
            self.assertEqual(catalog_api.api('accounts', {'source': 'youtube', 'source_id': 'UC-id'}), [])
            request = opener.call_args.args[0]
            self.assertEqual(request.get_header('Authorization'), 'Bearer local-key')
            self.assertIn('/api/catalog/accounts?source=youtube&source_id=UC-id', request.full_url)

    def test_redirect_cannot_forward_backend_credentials(self):
        request = Request('https://worker.example/api/catalog/accounts', headers={'Authorization': 'Bearer test'})
        with self.assertRaisesRegex(ValueError, 'redirect'):
            backend.NoRedirect().redirect_request(request, None, 302, '', {}, 'https://other.example')

    def test_local_cannot_impersonate_a_hosted_environment(self):
        with patch.dict(os.environ, {'BAZAARGHOST_API_URL': 'http://127.0.0.1:8787', 'ENVIRONMENT': 'production'}, clear=True):
            with self.assertRaises(ValueError):
                backend.selected_environment()
