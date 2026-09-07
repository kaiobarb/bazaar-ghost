"""HTTP persistence must fail closed and retry with stable detection identities."""
import base64
import logging
from unittest.mock import Mock
import pytest
from backend_client import BackendClient

@pytest.fixture
def client(monkeypatch):
    value = BackendClient.__new__(BackendClient)
    value.logger = logging.getLogger('test')
    value.quality, value.streamer = '480p', 'example'
    value.retry_attempts, value.claims = 2, {'abc': 'claim-token'}
    value._request = Mock(return_value={'storage_path': '/detections/123/abc/claim-token/detection_14.jpg'})
    monkeypatch.setattr('backend_client.time.sleep', lambda _: None)
    return value

def matchup():
    return {'vod_id': '123', 'chunk_id': 'abc', 'timestamp': 14, 'username': 'Opponent',
            'confidence': .95, 'igd': 9, 'frame_base64': base64.b64encode(b'jpeg').decode()}

def test_lost_insert_response_reuses_id(client):
    records = []
    def request(path, method, data, chunk, **kwargs):
        if method == 'PUT':
            return {'storage_path': '/detections/123/abc/claim-token/detection_14.jpg'}
        records.append(data['detections'])
        if len(records) == 1:
            raise TimeoutError('response lost')
        return {'published': 1}
    client._request.side_effect = request
    assert client.upload_batch([matchup()])
    assert records[0] == records[1]
    assert records[0][0]['igd'] == 9

def test_image_failure_never_publishes_detection(client):
    client._request.side_effect = RuntimeError('storage unavailable')
    with pytest.raises(RuntimeError, match='storage unavailable'):
        client.upload_batch([matchup()])
    assert all(call.args[1] == 'PUT' for call in client._request.call_args_list)

def test_missing_screenshot_is_not_published(client):
    item = matchup()
    del item['frame_base64']
    with pytest.raises(ValueError, match='screenshot'):
        client.upload_batch([item])
    client._request.assert_not_called()

def test_claim_token_is_kept_only_after_success(client):
    client._request.return_value = {'claimed': False, 'claim_token': None}
    assert not client.claim_chunk('new')
    assert 'new' not in client.claims
    client._request.return_value = {'claimed': True, 'claim_token': 'new-token'}
    assert client.claim_chunk('new')
    assert client.claims['new'] == 'new-token'
