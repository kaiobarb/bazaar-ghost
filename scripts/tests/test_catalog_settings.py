import contextlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import catalog_settings


ACCOUNT = '10000000-0000-4000-8000-000000000001'


class CatalogSettingsTests(unittest.TestCase):
    def run_command(self, arguments):
        with patch.object(sys, 'argv', ['catalog_settings', *arguments]), \
             patch.object(catalog_settings, 'api', return_value={'updated': True}) as api, \
             contextlib.redirect_stdout(io.StringIO()):
            catalog_settings.main()
        return api

    def test_clear_link_sends_explicit_null(self):
        self.run_command(['account', ACCOUNT, '--clear-streamer']).assert_called_once_with(
            f'accounts/{ACCOUNT}', method='PATCH', body={'streamer_id': None})

    def test_link_set_does_not_change_other_account_settings(self):
        self.run_command(['account', ACCOUNT, '--streamer-id', '15']).assert_called_once_with(
            f'accounts/{ACCOUNT}', method='PATCH', body={'streamer_id': 15})

    def test_video_profile_set_and_clear_preserve_expected_owner(self):
        for arguments, expected in [(['--profile-id', '3'], 3), (['--clear-profile'], None)]:
            with self.subTest(arguments=arguments):
                self.run_command(['video', '12', '--account-id', ACCOUNT, *arguments]).assert_called_once_with(
                    'videos/12', method='PATCH', body={'account_id': ACCOUNT, 'sfde_profile_id': expected})

    def test_invalid_or_ambiguous_targets_never_call_backend(self):
        for arguments in [
            ['account', '../videos/1', '--clear-streamer'],
            ['account', ACCOUNT, '--streamer-id', '2', '--clear-streamer'],
            ['video', '12', '--clear-profile'],
            ['video', '12', '--account-id', ACCOUNT, '--profile-id', '0'],
        ]:
            with self.subTest(arguments=arguments), patch.object(sys, 'argv', ['catalog_settings', *arguments]), \
                 patch.object(catalog_settings, 'api') as api, contextlib.redirect_stderr(io.StringIO()), \
                 self.assertRaises(SystemExit):
                catalog_settings.main()
            api.assert_not_called()


if __name__ == '__main__':
    unittest.main()
