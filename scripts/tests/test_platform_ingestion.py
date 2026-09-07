"""Automation contracts: readiness transitions, creator controls, and poll recovery."""

from pathlib import Path
import sys
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qs
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import platform_ingestion as ingestion
from platform_discovery import bazaar_title
from catalog_youtube import channel_page
from types import SimpleNamespace


class IngestionTests(unittest.TestCase):
    def setUp(self):
        self.account = {'id': 'account-1', 'source': 'youtube', 'source_id': 'UC0000000000000000000000',
                        'processing_enabled': True}
        self.job = {'id': 'job-1', 'source': 'youtube', 'kind': 'video', 'source_id': 'YouTube0001',
                    'account_id': 'account-1', 'lease_token': 'lease', 'state': {}}
        self.metadata = {'id': 'YouTube0001', 'channel_id': self.account['source_id'],
                         'title': 'The Bazaar build', 'duration': 3600, 'live_status': 'was_live'}

    def test_live_to_postlive_to_final_only_catalogs_final(self):
        with patch.object(ingestion, 'api', return_value=[self.account]), \
                patch.object(ingestion, 'save_video', return_value={'id': 12}) as save:
            for status in ('is_upcoming', 'is_live', 'post_live', 'was_live'):
                with patch.object(ingestion, 'youtube_metadata', return_value={**self.metadata, 'live_status': status}):
                    result = ingestion.ingest_video(self.job)
                self.assertEqual(result['status'], 'completed' if status == 'was_live' else 'waiting')
                self.assertEqual(save.call_count, int(status == 'was_live'))

    def test_existing_disabled_creator_is_never_reenabled_by_discovery(self):
        job = {**self.job, 'account_id': None}
        with patch.object(ingestion, 'youtube_metadata', return_value=self.metadata), \
                patch.object(ingestion, 'api', return_value=[{**self.account, 'processing_enabled': False}]), \
                patch.object(ingestion, 'youtube_account') as add, patch.object(ingestion, 'save_video') as save:
            self.assertEqual(ingestion.ingest_video(job)['status'], 'skipped')
            add.assert_not_called()
            save.assert_not_called()

    def test_owner_mismatch_never_catalogs_into_another_creator(self):
        with patch.object(ingestion, 'api', return_value=[{**self.account, 'id': 'different-account'}]):
            with self.assertRaisesRegex(ValueError, 'owner'):
                ingestion.verified_account('youtube', self.metadata, self.job)

    def test_new_matching_creator_is_automatically_enabled(self):
        with patch.object(ingestion, 'api', return_value=[]), \
                patch.object(ingestion, 'youtube_account', return_value=self.account) as add:
            ingestion.verified_account('youtube', self.metadata, {**self.job, 'account_id': None})
            self.assertTrue(add.call_args.args[2])

    def test_unrelated_video_does_not_enroll_creator(self):
        with patch.object(ingestion, 'youtube_metadata', return_value={**self.metadata, 'title': 'Other game'}), \
                patch.object(ingestion, 'verified_account') as add:
            self.assertEqual(ingestion.ingest_video(self.job)['status'], 'skipped')
            add.assert_not_called()

    def test_transport_failure_is_propagated_for_durable_retry(self):
        with patch.object(ingestion, 'youtube_metadata', side_effect=TimeoutError), \
                patch.object(ingestion, 'save_video') as save:
            with self.assertRaises(TimeoutError):
                ingestion.ingest_video(self.job)
            save.assert_not_called()

    def test_poll_paginates_until_previous_head_and_commits_only_persisted_ids(self):
        job = {**self.job, 'kind': 'account', 'state': {'videos': {'head': 'previous', 'start': 1}}}
        ids = [f'candidate-{index}' for index in range(20)]
        with patch.object(ingestion, 'api', return_value=[self.account]), \
                patch.object(ingestion, 'account_page', side_effect=[ids, []]), \
                patch.object(ingestion, 'enqueue') as enqueue, patch.object(ingestion, 'renew_subscription'):
            result = ingestion.poll_account(job)
            self.assertEqual(result['state']['videos'], {'head': 'previous', 'scan_head': ids[0], 'start': 21})
            self.assertEqual(result['delay'], 60)
            self.assertEqual(enqueue.call_count, 20)
        with patch.object(ingestion, 'api', return_value=[self.account]), \
                patch.object(ingestion, 'account_page', side_effect=[['previous'], []]), \
                patch.object(ingestion, 'enqueue'), patch.object(ingestion, 'renew_subscription'):
            result = ingestion.poll_account({**job, 'state': result['state']})
            self.assertEqual(result['state']['videos'], {'head': ids[0], 'start': 1})

    def test_failed_poll_or_queue_write_retains_cursor(self):
        state = {'videos': {'head': 'old', 'start': 21, 'scan_head': 'new'}}
        job = {**self.job, 'kind': 'account', 'state': state}
        with patch.object(ingestion, 'api', return_value=[self.account]), \
                patch.object(ingestion, 'account_page', side_effect=[['video'], []]), \
                patch.object(ingestion, 'enqueue', side_effect=TimeoutError), \
                patch.object(ingestion, 'renew_subscription'):
            result = ingestion.poll_account(job)
            self.assertEqual(result['state']['videos'], state['videos'])
            self.assertIsNotNone(result['error'])

    def test_bilibili_multipart_continuation_is_bounded_and_idempotent(self):
        pages = [{'cid': i + 1, 'page': i + 1, 'part': 'The Bazaar', 'duration': 60} for i in range(25)]
        metadata = {'bvid': 'BV1FfL5zPEbH', 'title': '大巴扎', 'pubdate': 1750000000, 'pages': pages}
        job = {**self.job, 'source': 'bilibili', 'source_id': metadata['bvid']}
        with patch.object(ingestion, 'video_metadata', return_value=metadata), \
                patch.object(ingestion, 'verified_account', return_value=self.account), \
                patch.object(ingestion, 'api'), patch.object(ingestion, 'save_video', return_value={'id': 1}) as save:
            result = ingestion.ingest_video(job)
            self.assertEqual(len(result['state']['seen_cids']), 20)
            self.assertEqual(save.call_count, 20)
            metadata['pages'] = list(reversed(metadata['pages']))
            result = ingestion.ingest_video({**job, 'state': result['state']})
            self.assertEqual(result['status'], 'completed')
            self.assertEqual(save.call_count, 25)

    def test_bilibili_search_markup_does_not_hide_game_evidence(self):
        self.assertTrue(bazaar_title('【<em class="keyword">大巴扎</em>】直播回放'))
        self.assertFalse(bazaar_title('Another game'))

    def test_absent_youtube_tab_is_distinct_from_an_access_failure(self):
        with patch('catalog_youtube.subprocess.run', return_value=SimpleNamespace(
                returncode=1, stderr='ERROR: This channel does not have a streams tab')):
            self.assertTrue(channel_page(self.account['source_id'], 1, 20, 'streams')['tab_absent'])
        with patch('catalog_youtube.subprocess.run', return_value=SimpleNamespace(
                returncode=1, stderr='ERROR: request blocked')):
            with self.assertRaises(RuntimeError):
                channel_page(self.account['source_id'], 1, 20, 'streams')

    def test_subscription_renewal_requests_a_signed_callback_before_lease_expiry(self):
        subscription = {'callback_token': 'capability', 'secret': 'test-secret', 'requested_at': None,
                        'lease_expires_at': (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()}
        with patch.dict(ingestion.os.environ, {'SUPABASE_URL': 'https://dev.example.test'}), \
                patch.object(ingestion, 'api', return_value=[subscription]) as api, \
                patch.object(ingestion, 'urlopen') as request:
            request.return_value.__enter__.return_value.status = 202
            ingestion.renew_subscription(self.account)
            params = parse_qs(request.call_args.args[0].data.decode())
            self.assertEqual(params['hub.secret'], ['test-secret'])
            self.assertIn('/functions/v1/youtube-webhook?', params['hub.callback'][0])
            self.assertIn('requested_at', api.call_args.args[2])
            request.reset_mock()
            subscription['lease_expires_at'] = (datetime.now(timezone.utc) + timedelta(days=3)).isoformat()
            ingestion.renew_subscription(self.account)
            request.assert_not_called()

    def test_hub_failure_is_recorded_without_breaking_polling(self):
        subscription = {'callback_token': 'capability', 'secret': 'test-secret', 'requested_at': None}
        with patch.dict(ingestion.os.environ, {'SUPABASE_URL': 'https://dev.example.test'}), \
                patch.object(ingestion, 'api', return_value=[subscription]) as api, \
                patch.object(ingestion, 'urlopen', side_effect=TimeoutError):
            ingestion.renew_subscription(self.account)
            self.assertEqual(api.call_args.args[2]['last_error'], 'TimeoutError: subscription request failed')


if __name__ == '__main__':
    unittest.main()
