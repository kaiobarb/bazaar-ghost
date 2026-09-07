"""Pipeline contracts: EOF drains work, errors fail chunks, timestamps stay attached."""

import io
import logging
import threading
import time
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from sfde import SFDEProcessor
from video import read_jpegs, timestamped_frames


class FragmentedStream(io.BytesIO):
    def read(self, size=-1):
        return super().read(min(size, 1))


def test_jpeg_markers_split_across_reads():
    assert list(read_jpegs(FragmentedStream(b'\xff\xd8a\xff\xd9\xff\xd8b\xff\xd9'))) == [
        b'\xff\xd8a\xff\xd9', b'\xff\xd8b\xff\xd9',
    ]


def test_truncated_jpeg_fails():
    with pytest.raises(ValueError, match='incomplete'):
        list(read_jpegs(io.BytesIO(b'\xff\xd8partial')))


def test_frame_timestamp_pairing():
    pixels = io.BytesIO(b'\xff\xd8a\xff\xd9\xff\xd8b\xff\xd9')
    pts = io.BytesIO(b'[showinfo] pts_time:0.0 duration:2\n[showinfo] pts_time:2e+0 duration:2\n')
    assert [ts for _, ts in timestamped_frames(pixels, pts, logging.getLogger())] == [0, 2]


def test_missing_pts_does_not_invent_a_timestamp():
    with pytest.raises(RuntimeError, match='without its timestamp'):
        list(timestamped_frames(io.BytesIO(b'\xff\xd8a\xff\xd9'), io.BytesIO(), logging.getLogger()))


@pytest.fixture
def processor(monkeypatch, tmp_path):
    import sfde

    db = Mock()
    db.get_chunk_details.return_value = {
        'vod_id': '123', 'start_seconds': 0, 'end_seconds': 300, 'status': 'pending',
    }
    db.claim_chunk.return_value = True
    monkeypatch.setattr(sfde, 'BackendClient', Mock(return_value=db))
    reader = SimpleNamespace(process_frame=lambda frame, timestamp, vod, chunk: {
        'username': 'Opponent', 'timestamp': timestamp, 'is_matchup': True,
    })
    monkeypatch.setattr(sfde, 'FrameProcessor', Mock(return_value=reader))
    monkeypatch.setenv('SFDE_PROFILE', '{"crop_region":[0.5,0.5,0.4,0.2]}')
    monkeypatch.delenv('OTEL_EXPORTER_OTLP_ENDPOINT', raising=False)
    monkeypatch.setattr(sfde.signal, 'signal', lambda *args: None)
    value = SFDEProcessor({'chunk_id': 'test', 'test_mode': True})
    value.frame_queue.maxsize = 2
    value.result_queue.maxsize = 2
    value.export_detection_summary = lambda: None
    return value


def test_eof_drains_frames_results_and_final_batch(processor):
    def decode():
        for timestamp in range(101):
            processor._put(processor.frame_queue, (b'frame', timestamp))
    processor.ffmpeg_worker = decode
    result = processor.process_vod_chunk()
    assert result['status'] == 'completed'
    assert result['frames_processed'] == 101
    assert len(processor.all_detections) == 101
    assert [item['timestamp'] for item in processor.all_detections] == list(range(101))
    assert processor.backend.upload_batch.call_count == 11
    assert not any(thread.is_alive() for thread in processor.threads)


def test_decoder_error_after_frames_fails_chunk(processor):
    def decode():
        processor._put(processor.frame_queue, (b'frame', 0))
        raise RuntimeError('decoder failure')
    processor.ffmpeg_worker = decode
    with pytest.raises(RuntimeError, match='decoder failure'):
        processor.process_vod_chunk()
    assert processor.backend.update_chunk.call_args.args[1] == 'failed'


def test_upload_error_is_not_reported_as_completion(processor):
    processor.ffmpeg_worker = lambda: processor._put(processor.frame_queue, (b'frame', 0))
    processor.backend.upload_batch.side_effect = RuntimeError('database unavailable')
    with pytest.raises(RuntimeError, match='database unavailable'):
        processor.process_vod_chunk()
    assert processor.backend.update_chunk.call_args.args[1] == 'failed'


def test_empty_decode_fails_chunk(processor):
    processor.ffmpeg_worker = lambda: None
    with pytest.raises(RuntimeError, match='no frames'):
        processor.process_vod_chunk()


def test_unclaimed_chunk_does_not_delete_or_rewrite_other_worker(processor):
    processor.backend.claim_chunk.return_value = False
    with pytest.raises(ValueError, match='not pending or queued'):
        processor.process_vod_chunk()
    processor.backend.delete_chunk_detections.assert_not_called()
    processor.backend.update_chunk.assert_not_called()


def test_deadline_cancels_workers(processor):
    processor.config['processing']['timeout'] = 0.01
    processor.ffmpeg_worker = lambda: processor.shutdown.wait(2)
    with pytest.raises(TimeoutError):
        processor.process_vod_chunk()
    assert not any(thread.is_alive() for thread in processor.threads)


@pytest.mark.parametrize('region', [[-0.1, 0, 1, 1], [0, 0, 0, 1], [0.5, 0, 1, 1], [0, 0, 'NaN', 1]])
def test_invalid_profile_crop_rejected(monkeypatch, region):
    import json
    monkeypatch.setenv('SFDE_PROFILE', json.dumps({'crop_region': region}))
    with pytest.raises(ValueError):
        SFDEProcessor.__new__(SFDEProcessor)._parse_sfde_profile()

@pytest.mark.parametrize('days,expected', [([8], 8), ([None], None)])
def test_igd_pending_detection_survives_eof(processor, days, expected):
    import numpy as np
    processor._igd_slice = [0, 0, 2, 2]
    processor._nameplate_slice = [0, 0, 2, 2]
    processor._decode_jpeg = lambda _: np.zeros((2, 2, 3), dtype=np.uint8)
    processor._encode_jpeg = lambda _: b'frame'
    processor.frame_processor.process_frame = Mock(side_effect=[
        {'is_matchup': True, 'username': 'first', 'timestamp': 0}, None,
    ])
    processor.frame_processor.extract_igd = Mock(side_effect=days)
    processor.frame_queue.put((b'frame', 0))
    processor.frame_queue.put((b'frame', 2))
    processor.frames_done.set()
    processor.opencv_worker()
    assert processor.result_queue.get_nowait().get('igd') == expected
    assert processor.result_queue.empty()


def test_new_matchup_day_is_not_assigned_to_previous_matchup(processor):
    import numpy as np
    processor.result_queue.maxsize = 3
    processor._igd_slice = [0, 0, 2, 2]
    processor._nameplate_slice = [0, 0, 2, 2]
    processor._decode_jpeg = lambda _: np.zeros((2, 2, 3), dtype=np.uint8)
    processor._encode_jpeg = lambda _: b'frame'
    processor.frame_processor.process_frame = Mock(side_effect=[
        {'is_matchup': True, 'username': 'first', 'timestamp': 0},
        {'is_matchup': True, 'username': 'second', 'timestamp': 2},
    ])
    processor.frame_processor.extract_igd = Mock(return_value=9)
    processor.frame_queue.put((b'frame', 0))
    processor.frame_queue.put((b'frame', 2))
    processor.frames_done.set()
    processor.opencv_worker()
    results = [processor.result_queue.get_nowait() for _ in range(2)]
    assert [row['username'] for row in results] == ['first', 'second']
    assert all(row.get('igd') is None for row in results)
    processor.frame_processor.extract_igd.assert_not_called()
