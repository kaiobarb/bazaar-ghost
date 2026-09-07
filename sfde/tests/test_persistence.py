"""Persistence failures must not publish broken images or duplicate notifications."""
import base64
import logging
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from supabase_client import SupabaseClient


@pytest.fixture
def client(monkeypatch):
    value = SupabaseClient.__new__(SupabaseClient)
    value.client = Mock()
    value.logger = logging.getLogger('test')
    value.quality = '480p'
    value.test_mode = False
    value.streamer = 'example'
    value.storage_bucket = 'detections'
    value.retry_attempts = 2
    value.client.table.return_value.select.return_value.eq.return_value.eq.return_value.single.return_value.execute.return_value = SimpleNamespace(data={'id': 1})
    monkeypatch.setattr('supabase_client.time.sleep', lambda _: None)
    return value


def matchup():
    return {'vod_id': '123', 'chunk_id': 'abc', 'timestamp': 14, 'username': 'Opponent',
            'frame_base64': base64.b64encode(b'jpeg').decode()}


def test_lost_insert_response_reuses_id_and_ignores_duplicate(client):
    records = []
    def upsert(rows, **options):
        records.append(rows)
        assert options == {'on_conflict': 'id', 'ignore_duplicates': True}
        if len(records) == 1:
            return SimpleNamespace(execute=Mock(side_effect=TimeoutError('response lost')))
        return SimpleNamespace(execute=Mock())
    client.client.table.return_value.upsert.side_effect = upsert
    assert client.upload_batch([matchup()])
    assert records[0] == records[1]
    assert records[0][0]['storage_path'] == '/detections/123/14.jpg'


def test_image_failure_never_publishes_detection(client):
    client.client.storage.from_.return_value.upload.side_effect = RuntimeError('storage unavailable')
    with pytest.raises(RuntimeError, match='storage unavailable'):
        client.upload_batch([matchup()])
    client.client.table.return_value.upsert.assert_not_called()


def test_lookup_failure_is_not_a_silently_empty_batch(client):
    client.client.table.return_value.select.return_value.eq.return_value.eq.return_value.single.return_value.execute.side_effect = RuntimeError('missing VOD')
    with pytest.raises(RuntimeError, match='missing VOD'):
        client.upload_batch([matchup()])
    client.client.table.return_value.upsert.assert_not_called()
