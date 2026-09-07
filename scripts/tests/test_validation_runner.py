import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).resolve().parents[1] / 'validation_runner'
sys.path.insert(0, str(RUNNER))


def load(name):
    spec = importlib.util.spec_from_file_location('validation_' + name, RUNNER / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


validation, launcher, start, guard = (load(name) for name in ('validate', 'launch', 'start', 'guard'))
VALUES = {'GITHUB_REPOSITORY': guard.REPOSITORY, 'GITHUB_REF': guard.REF, 'GITHUB_EVENT_NAME': 'workflow_dispatch',
          'GITHUB_WORKFLOW_REF': guard.WORKFLOW, 'GITHUB_SHA': 'a' * 40, 'GITHUB_RUN_ID': '123',
          'GITHUB_ACTIONS': 'true', 'ENVIRONMENT': 'validation', 'VALIDATION_SOURCE': 'youtube',
          'VALIDATION_VIDEO_ID': '0C6bxQsDj-s', 'VALIDATION_RANGES': '[0,900]', 'VALIDATION_TEMPLATES': 'current',
          'VALIDATION_QUALITY': '480p', 'VALIDATION_PROFILE_ID': '1', 'VALIDATION_MINIMUM_DETECTIONS': '1',
          'VALIDATION_REQUIRE_IGD': 'true', 'BAZAARGHOST_API_URL': 'https://validation.example',
          'BAZAARGHOST_CATALOG_KEY': 'test-catalog', 'BAZAARGHOST_PROCESSOR_KEY': 'test-processor'}
CHUNK = {'id': '00000000-0000-4000-8000-000000000001', 'vod_pk': 1, 'source': 'youtube', 'vod_id': '0C6bxQsDj-s',
         'status': 'pending', 'start_seconds': 0, 'end_seconds': 900}
SUMMARY = {'vod_pk': 1, 'source': 'youtube', 'vod_id': CHUNK['vod_id'], 'chunk_id': CHUNK['id'], 'start_time': 0, 'end_time': 900, 'frames_processed': 450, 'matchups_found': 1,
           'detections': [{'timestamp': 12, 'username': 'Opponent', 'confidence': 0.95, 'rank': 'gold', 'igd': 12}],
           'decode_coverage': {'sampled_frames': 450, 'minimum_expected_frames': 450, 'sample_interval_seconds': 2,
                               'first_sample_seconds': 0, 'last_sample_seconds': 898,
                               'requested_start_seconds': 0, 'requested_end_seconds': 900}}
STATE = {**CHUNK, 'status': 'completed', 'frames_processed': 450, 'detections_count': 1}


class ValidationRunnerTests(unittest.TestCase):
    def test_job_boundary_rejects_every_other_branch_repository_workflow_and_event(self):
        guard.validate_job(VALUES)
        for name, value in [('GITHUB_REF', 'refs/heads/dev'), ('GITHUB_REPOSITORY', 'other/repo'),
                            ('GITHUB_WORKFLOW_REF', guard.WORKFLOW.replace('validate-recording', 'process-vod')),
                            ('GITHUB_EVENT_NAME', 'pull_request')]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                guard.validate_job({**VALUES, name: value})

    def test_registration_secret_is_only_an_environment_input_and_runner_is_ephemeral(self):
        token = 'private-test-token'
        command, private = start.registration('bazaarghost-validation-' + 'a' * 32, token)
        self.assertNotIn(token, ' '.join(command))
        self.assertNotIn('--token', command)
        self.assertEqual(private, {'ACTIONS_RUNNER_INPUT_TOKEN': token})
        for flag in ('--ephemeral', '--disableupdate', '--no-default-labels'):
            self.assertIn(flag, command)
        self.assertNotIn('--replace', command)

    def test_container_has_no_host_mount_or_network_host_or_credential_argument(self):
        command = launcher.container_command('bazaarghost-validation-' + 'b' * 32, 'bazaarghost-validation-runner:2.337.0')
        for flag in ('-v', '--volume', '--mount', '--privileged', '--network=host', '--network', '--env-file'):
            self.assertNotIn(flag, command)
        self.assertIn('--cap-drop=ALL', command)
        self.assertIn('--security-opt=no-new-privileges', command)
        self.assertIn('--pull=never', command)
        with self.assertRaises(ValueError):
            launcher.container_command('self-hosted', 'image')
        with self.assertRaises(ValueError):
            launcher.container_command('bazaarghost-validation-' + 'b' * 32, '-v/home:/host')

    def test_bounded_reviewed_inputs_reject_boolean_ranges_overlap_and_template_mismatch(self):
        self.assertEqual(validation.options(VALUES)['ranges'], [0, 900])
        changes = [('ENVIRONMENT', 'dev'), ('VALIDATION_SOURCE', 'twitch'), ('VALIDATION_VIDEO_ID', 'https://evil.invalid'),
                   ('VALIDATION_RANGES', '[false,900]'), ('VALIDATION_RANGES', '[0,900,800,1000]'),
                   ('VALIDATION_RANGES', '[0,1801]'), ('VALIDATION_RANGES', '[0,1800,2000,3800,4000,4100]'),
                   ('VALIDATION_MINIMUM_DETECTIONS', '0'), ('VALIDATION_PROFILE_ID', '-1')]
        for name, value in changes:
            with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                validation.options({**VALUES, name: value})
        with self.assertRaises(ValueError):
            validation.options({**VALUES, 'VALIDATION_TEMPLATES': 'old', 'VALIDATION_QUALITY': '720p'})

    def test_plan_proof_requires_exact_ranges_source_and_fresh_unclaimed_chunks(self):
        selected = validation.options(VALUES)
        validation.verify_plan([CHUNK], selected, 1)
        for changes in ({'end_seconds': 899}, {'start_seconds': 1}, {'vod_pk': 2}, {'source': 'twitch'}, {'status': 'completed'}, {'status': 'queued'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validation.verify_plan([{**CHUNK, **changes}], selected, 1)
        with self.assertRaises(ValueError):
            validation.verify_plan([CHUNK, CHUNK], selected, 1)

    def test_clean_early_eof_and_wrong_sample_timeline_cannot_pass_terminal_coverage(self):
        self.assertEqual(validation.verify_chunk(CHUNK, STATE, SUMMARY)['frames_processed'], 450)
        for field, value in [('sampled_frames', 449), ('last_sample_seconds', 896), ('first_sample_seconds', 2),
                             ('sample_interval_seconds', 3), ('requested_end_seconds', 899)]:
            summary = copy.deepcopy(SUMMARY)
            summary['decode_coverage'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validation.verify_chunk(CHUNK, STATE, summary)
        for state in ({**STATE, 'status': 'processing'}, {**STATE, 'frames_processed': 449}, {**STATE, 'detections_count': 0},
                      {**STATE, 'vod_pk': 2}, {**STATE, 'source': 'twitch'}, {**STATE, 'id': 'another-chunk'}):
            with self.assertRaises(ValueError):
                validation.verify_chunk(CHUNK, state, SUMMARY)

    def test_ocr_subprocess_does_not_inherit_catalog_registration_or_ambient_credentials(self):
        prepared = {'quality': '480p', 'video_fps': '30', 'sfde_profile': '{}', 'old_templates': 'false'}
        with patch.dict(os.environ, {**VALUES, 'ACTIONS_RUNNER_INPUT_TOKEN': 'registration', 'AUTH_SECRET': 'auth',
                                    'HTTP_PROXY': 'private-proxy', 'TEST_MODE': 'true', 'GH_TOKEN': 'gh'}, clear=True):
            result = validation.processor_environment(prepared, CHUNK['id'])
        self.assertEqual(result['BAZAARGHOST_PROCESSOR_KEY'], 'test-processor')
        self.assertEqual(result['TEST_MODE'], 'false')
        for key in ('BAZAARGHOST_CATALOG_KEY', 'ACTIONS_RUNNER_INPUT_TOKEN', 'AUTH_SECRET', 'HTTP_PROXY', 'GH_TOKEN'):
            self.assertNotIn(key, result)

    def test_full_orchestration_validates_health_before_catalog_and_publishes_proof_without_secrets(self):
        order, processed = [], []
        first = {**CHUNK, 'end_seconds': 1800}
        second = {**CHUNK, 'id': '00000000-0000-4000-8000-000000000002', 'start_seconds': 1800, 'end_seconds': 2718}
        chunks = [first, second]
        summaries = {}
        for chunk in chunks:
            count = (chunk['end_seconds'] - chunk['start_seconds']) // 2
            summary = copy.deepcopy(SUMMARY)
            summary.update(chunk_id=chunk['id'], start_time=chunk['start_seconds'], end_time=chunk['end_seconds'], frames_processed=count)
            summary['detections'][0]['timestamp'] = chunk['start_seconds'] + 12
            summary['decode_coverage'].update(sampled_frames=count, minimum_expected_frames=count,
                first_sample_seconds=chunk['start_seconds'], last_sample_seconds=chunk['end_seconds'] - 2,
                requested_start_seconds=chunk['start_seconds'], requested_end_seconds=chunk['end_seconds'])
            summaries[chunk['id']] = summary
        states = [{**chunk, 'status': 'completed', 'frames_processed': summaries[chunk['id']]['frames_processed'], 'detections_count': 1}
                  for chunk in chunks]
        values = {**VALUES, 'VALIDATION_RANGES': '[0,1800,1800,2718]', 'VALIDATION_PROFILE_ID': '2'}
        class Image:
            status = 200
            class Headers:
                def get_content_type(self): return 'image/jpeg'
            headers = Headers()
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, size): return b'\xff\xd8\xff'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'sfde').mkdir()
            (root / 'ocr').mkdir()
            def process(command, **kwargs):
                if command[-1] == 'prepare':
                    Path(kwargs['env']['GITHUB_OUTPUT']).write_text('chunk_uuids=' + json.dumps([chunk['id'] for chunk in chunks]) + '\nquality=480p\nvideo_fps=30\nold_templates=false\nsfde_profile={"id":2}\n')
                else:
                    chunk_id = kwargs['env']['CHUNK_ID']
                    processed.append(chunk_id)
                    (root / 'ocr' / f'detections_{chunk_id}.json').write_text(json.dumps(summaries[chunk_id]))
            def public(path, data=None):
                if path == '/health': return {'ok': True, 'environment': 'validation', 'build_commit': 'b' * 40}
                return [{'vod_id': 1, 'source': 'youtube', 'source_id': CHUNK['vod_id'], 'detection_id': 'public-' + chunk['id'],
                         'frame_time_seconds': chunk['start_seconds'] + 12, 'username': 'Opponent', 'rank': 'gold', 'igd': 12,
                         'storage_path': '/detections/example/current.jpg'} for chunk in chunks]
            with patch.dict(os.environ, values, clear=True), patch.object(validation, 'ROOT', root), patch.object(validation, 'OCR_OUTPUT', root / 'ocr'), \
                 patch.object(validation, 'verify_backend', side_effect=lambda: order.append('health')), \
                 patch.object(validation, 'youtube_metadata', side_effect=lambda value: order.append('metadata') or {'channel_id': 'UCtest'}), \
                 patch.object(validation, 'normalize_video', return_value={'duration_seconds': 2718}), \
                 patch.object(validation, 'ensure_account', side_effect=lambda *args, **kwargs: order.append('credential') or {'id': 'account'}), \
                 patch.object(validation, 'save_video', return_value={'id': 1}), patch.object(validation, 'public_json', side_effect=public), \
                 patch.object(validation, 'verify_jpeg', return_value={'bytes': 1200, 'width': 854, 'height': 480}), \
                 patch.object(validation, 'open_backend', return_value=Image()), patch.object(validation.subprocess, 'run', side_effect=process), \
                 patch.object(validation.subprocess, 'check_output', return_value='a' * 40), \
                 patch.object(validation.vod_workflow, 'api', side_effect=[*chunks, *states]), \
                 patch.object(validation.vod_workflow, 'get_vod', return_value={'status': 'completed'}):
                self.assertEqual(validation.main(), 0)
            report = json.loads((root / 'validation-output' / 'validation.json').read_text())
            self.assertEqual(report['status'], 'passed')
            self.assertEqual([chunk['frames_processed'] for chunk in report['chunks']], [900, 459])
            self.assertEqual(report['frames_processed'], 1359)
            self.assertEqual(report['profile']['id'], 2)
            self.assertEqual(report['cataloged_ranges'], [[0, 2718]])
            self.assertTrue(report['full_source_video'])
            self.assertEqual(processed, [chunk['id'] for chunk in chunks])
            self.assertEqual(report['igd_detections'], 2)
            self.assertEqual(order, ['health', 'metadata', 'credential'])
            self.assertNotIn('test-processor', json.dumps(report))
            self.assertNotIn('test-catalog', json.dumps(report))
            self.assertEqual((root / 'validation-output' / 'validation.json').stat().st_mode & 0o777, 0o600)

    @unittest.skipUnless(importlib.util.find_spec('PIL'), 'Pillow runs in the OCR image; no host package installation')
    def test_jpeg_evidence_fully_decodes_and_rejects_truncation_wrong_format_and_oversize(self):
        from PIL import Image
        payload = io.BytesIO()
        Image.new('RGB', (32, 16), 'red').save(payload, format='JPEG')
        self.assertEqual(validation.verify_jpeg(payload.getvalue())['width'], 32)
        with self.assertRaises(validation.ValidationFailure):
            validation.verify_jpeg(payload.getvalue()[:-20])
        png = io.BytesIO()
        Image.new('RGB', (32, 16), 'red').save(png, format='PNG')
        with self.assertRaises(validation.ValidationFailure):
            validation.verify_jpeg(png.getvalue())
        with patch.object(validation, 'MAX_JPEG_PIXELS', 100), self.assertRaises(validation.ValidationFailure):
            validation.verify_jpeg(payload.getvalue())
        with patch.object(validation, 'MAX_JPEG_BYTES', 100), self.assertRaises(validation.ValidationFailure):
            validation.verify_jpeg(payload.getvalue())
