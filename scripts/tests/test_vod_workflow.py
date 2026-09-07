import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('workflow', Path(__file__).resolve().parents[1] / 'vod_workflow.py')
workflow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(workflow)


class WorkflowTests(unittest.TestCase):
    def test_respects_requested_quality(self):
        self.assertEqual(workflow.select_quality({'480p': {}, '720p60': {}}, '720p', False), '720p60')

    def test_old_templates_require_480p(self):
        with self.assertRaises(ValueError):
            workflow.select_quality({'720p': {}}, '720p', True)
        self.assertEqual(workflow.select_quality({'720p': {}, '480p60': {}}, '720p', True), '480p60')

    def test_unsupported_quality_is_rejected(self):
        with self.assertRaises(ValueError):
            workflow.select_quality({'best': {}}, 'best', False)

    def test_no_rendition_is_not_assumed_available(self):
        with self.assertRaises(ValueError):
            workflow.select_quality({}, '480p', False)

    def test_video_lookup_is_scoped_to_source_and_preserves_case(self):
        with patch.dict(workflow.os.environ, {'VOD_ID': '0C6bxQsDj-s', 'VIDEO_SOURCE': 'youtube'}, clear=True), \
                patch.object(workflow, 'api', return_value={'id': 1}) as api:
            self.assertEqual(workflow.get_vod(), {'id': 1})
            api.assert_called_once_with('vod', {'source': 'youtube', 'source_id': '0C6bxQsDj-s'})

    def test_old_external_archive_uses_profile_and_480p_without_publication_guessing(self):
        chunk = '2e032210-c665-4e6c-9f97-80b4c930c153'
        vod = {'id': 1, 'source': 'bilibili', 'processing_enabled': True,
               'ready_for_processing': True, 'availability': 'available', 'old_templates': True,
               'profile': {'crop_region': [0, 0, 1, 1]}, 'published_at': '2026-09-07T00:00:00Z'}
        values = {'VOD_ID': 'BV1FfL5zPEbH:20', 'VIDEO_SOURCE': 'bilibili', 'LOCAL': 'true',
                  'REQUESTED_QUALITY': '720p', 'QUEUED_AT': '2026-09-07T12:00:00Z'}
        with patch.dict(workflow.os.environ, values, clear=True), patch.object(workflow, 'get_vod', return_value=vod), \
                patch.object(workflow, 'api', return_value=[{'id': chunk}]) as api, patch.object(workflow, 'output') as output:
            workflow.prepare()
            self.assertEqual(api.call_args.args[1]['queued_at'], values['QUEUED_AT'])
            outputs = dict(call.args for call in output.call_args_list)
            self.assertEqual(outputs['quality'], '480p')
            self.assertEqual(outputs['old_templates'], 'true')
            self.assertEqual(outputs['sfde_profile'], vod['profile'])

    def test_failure_cleanup_retains_dispatch_fencing(self):
        chunk = '2e032210-c665-4e6c-9f97-80b4c930c153'
        with patch.dict(workflow.os.environ, {'CHUNK_ID': chunk, 'QUEUED_AT': '2026-09-07T12:00:00Z'}, clear=True), \
                patch.object(workflow, 'api') as api:
            workflow.fail_chunk()
            self.assertEqual(api.call_args.kwargs['body']['queued_at'], '2026-09-07T12:00:00Z')
            self.assertEqual(api.call_args.kwargs['body']['ids'], [chunk])


if __name__ == '__main__':
    unittest.main()
