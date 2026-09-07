import importlib.util
from pathlib import Path
import unittest

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


if __name__ == '__main__':
    unittest.main()
