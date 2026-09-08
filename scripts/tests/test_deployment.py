import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('deployment', ROOT / 'scripts/deployment_check.py')
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.configs = {}
        for number, target in enumerate(deployment.BRANCHES, 1):
            config = deployment.read_jsonc(ROOT / f'wrangler.{target}.jsonc')
            config['d1_databases'][0]['database_id'] = f'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaa{number}'
            config['workers_dev'] = True
            config['vars']['PUBLIC_URL'] = f'https://bazaarghost-{target}.example.workers.dev'
            self.configs[target] = config
        self.write_configs()

    def write_configs(self):
        for target, config in self.configs.items():
            (self.root / f'wrangler.{target}.jsonc').write_text(json.dumps(config))

    def validate(self, target='validation', ref=None):
        self.write_configs()
        return deployment.validate(target, self.root, ref=ref or deployment.BRANCHES[target])

    def test_all_environments_validate_when_concrete_and_isolated(self):
        for target in deployment.BRANCHES:
            with self.subTest(target=target):
                self.assertEqual(self.validate(target)['vars']['ENVIRONMENT'], target)

    def test_auth_maintenance_is_the_only_validation_schedule_and_preserves_other_environments(self):
        provider_schedules = ['*/3 * * * *', '0 * * * *', '0 0,12 * * *', '0 2 * * *', '0 3 * * *']
        for target in ['local', 'dev', 'production', 'validation']:
            filename = 'wrangler.jsonc' if target == 'local' else f'wrangler.{target}.jsonc'
            config = deployment.read_jsonc(ROOT / filename)
            with self.subTest(target=target):
                expected = ['* * * * *'] + ([] if target == 'validation' else provider_schedules)
                self.assertEqual(config['triggers']['crons'], expected)
                self.assertEqual(config['vars']['ENVIRONMENT'], target)
                self.assertEqual(config['vars']['OUTBOUND_ENABLED'], 'false')

    def test_rejects_cross_environment_branch_and_tags(self):
        for ref in ['refs/heads/dev', 'refs/heads/main', 'refs/tags/codex/cloudflare-validation']:
            with self.subTest(ref=ref), self.assertRaisesRegex(ValueError, 'requires branch'):
                self.validate(ref=ref)

    def test_rejects_production_database_even_when_uuid_case_differs(self):
        self.configs['validation']['d1_databases'][0]['database_id'] = self.configs['production']['d1_databases'][0]['database_id'].upper()
        with self.assertRaisesRegex(ValueError, 'must not share a database'):
            self.validate()

    def test_rejects_wrong_worker_database_and_bucket_names(self):
        original = copy.deepcopy(self.configs['validation'])
        for field in ['name', 'database', 'bucket']:
            self.configs['validation'] = copy.deepcopy(original)
            config = self.configs['validation']
            if field == 'name':
                config['name'] = 'bazaarghost-production'
            elif field == 'database':
                config['d1_databases'][0]['database_name'] = 'bazaarghost-production'
            else:
                config['r2_buckets'][0]['bucket_name'] = 'bazaarghost-detections-production'
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.validate()

    def test_rejects_primary_and_dead_letter_queue_reuse(self):
        original = copy.deepcopy(self.configs['validation'])
        for key in ['queue', 'dead_letter_queue']:
            self.configs['validation'] = copy.deepcopy(original)
            self.configs['validation']['queues']['consumers'][0][key] = 'bazaarghost-production'
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'queues'):
                self.validate()

    def test_rejects_any_custom_domain_in_validation(self):
        for key in ['route', 'routes']:
            self.configs['validation'][key] = ['bazaarghost.stream/*'] if key == 'routes' else 'bazaarghost.stream/*'
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'dedicated workers.dev'):
                self.validate()
            del self.configs['validation'][key]

    def test_rejects_placeholder_database_and_unsafe_urls(self):
        original = copy.deepcopy(self.configs['validation'])
        self.configs['validation']['d1_databases'][0]['database_id'] = deployment.ZERO_UUID
        with self.assertRaisesRegex(ValueError, 'provisioned D1'):
            self.validate()
        for url in ['http://example.com', 'https://user:password@example.com', 'https://example.com/path',
                    'https://example.com?query=yes', 'https://bazaarghost-production.example.workers.dev',
                    'https://bazaarghost-validation.REPLACE_ME.workers.dev']:
            self.configs['validation'] = copy.deepcopy(original)
            self.configs['validation']['vars']['PUBLIC_URL'] = url
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.validate()

    def test_detects_queue_collision_from_the_other_configuration(self):
        self.configs['production']['queues']['consumers'][0]['dead_letter_queue'] = 'bazaarghost-validation-dlq'
        with self.assertRaisesRegex(ValueError, 'must not share a queue'):
            self.validate()

    def test_missing_comparison_configuration_fails_closed(self):
        (self.root / 'wrangler.production.jsonc').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing comparison'):
            deployment.validate('validation', self.root)

    def test_jsonc_preserves_string_content_and_accepts_comments_and_trailing_commas(self):
        path = self.root / 'syntax.jsonc'
        path.write_text(r'''{
            // Comment containing "quotes"
            "url": "https://example.com/with//slashes",
            "text": "/* literal */ ,} ,] escaped \"quote\"",
            "array": [1, /* after comma */ 2,],
        }''')
        self.assertEqual(deployment.read_jsonc(path), {
            'url': 'https://example.com/with//slashes',
            'text': '/* literal */ ,} ,] escaped "quote"',
            'array': [1, 2],
        })

    def test_jsonc_does_not_join_invalid_tokens(self):
        path = self.root / 'invalid.jsonc'
        for text in ['{"number": 1 2}', '{"number": 1/* comment */2}', '{/*unclosed']:
            path.write_text(text)
            with self.subTest(text=text), self.assertRaises(ValueError):
                deployment.read_jsonc(path)


if __name__ == '__main__':
    unittest.main()
