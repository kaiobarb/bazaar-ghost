import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('convert', Path(__file__).resolve().parents[1] / 'migration' / 'convert.py')
conversion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(conversion)


class MigrationTests(unittest.TestCase):
    def test_snapshot_roundtrip_preserves_ids_and_does_not_replay_notifications(self):
        with tempfile.TemporaryDirectory() as root:
            source, dest = Path(root) / 'source', Path(root) / 'output'
            source.mkdir()
            records = {
                'sfde_profiles': [{'id': 1, 'profile_name': 'default', 'crop_region': [0, 0, 1, 1]}],
                'streamers': [{'id': 1, 'login': 'example', 'processing_enabled': True}],
                'vods': [{'id': 1, 'streamer_id': 1, 'source_id': '123', 'duration_seconds': 12, 'bazaar_chapters': [0, 12], 'status': 'completed'}],
                'chunks': [{'id': 'chunk', 'vod_id': 1, 'start_seconds': 0, 'end_seconds': 12, 'chunk_index': 0, 'status': 'completed'}],
                'detections': [{'id': 'detection', 'chunk_id': 'chunk', 'vod_id': 1, 'username': "O'Connor", 'frame_time_seconds': 0, 'confidence': .95, 'igd': 9, 'storage_path': '/detections/123/0.jpg'}],
            }
            for table in conversion.TABLES:
                (source / (table + '.jsonl')).write_text(''.join(json.dumps(r) + '\n' for r in records.get(table, [])))
            conversion.convert(source, dest)
            restored = sqlite3.connect(':memory:')
            restored.execute('PRAGMA foreign_keys=ON')
            restored.executescript((conversion.ROOT / 'worker/migrations/0001_backend.sql').read_text())
            restored.executescript((dest / 'import.sql').read_text())
            self.assertEqual(restored.execute('SELECT username,igd FROM detections').fetchone(), ("O'Connor", 9))
            self.assertTrue(restored.execute('SELECT sent_at FROM notification_outbox').fetchone()[0])
            self.assertEqual(restored.execute('PRAGMA foreign_key_check').fetchall(), [])
            self.assertEqual(restored.execute('SELECT status FROM vods').fetchone()[0], 'completed')

    def test_trigrams_match_worker_word_padding(self):
        self.assertEqual(conversion.trigrams('CAT-cat'), ['  c', ' ca', 'at ', 'cat'])
        self.assertEqual(conversion.trigrams('é'), ['  é', ' é '])
