"""Production frame behavior without loading OCR models."""

import logging
from unittest.mock import Mock

import cv2
import numpy as np
import pytest

from frame_processor import FrameProcessor
from emblem_detector import EmblemDetector
from right_edge_detector import RightEdgeDetector


@pytest.fixture
def processor():
    result = FrameProcessor.__new__(FrameProcessor)
    result.logger = logging.getLogger('test')
    result.streamer = 'test'
    result.quality = '480p'
    result.last_matchup_time = None
    result.min_matchup_interval = 10
    result.ocr_confidence_threshold = 0.5
    result.right_edge_crop_margin = 0.05
    result.opaque_edge = True
    result.custom_edge_percent = 0.8
    result.emblem_detector = None
    result.right_edge_detector = None
    result._detect_emblem = Mock(return_value=('gold', (0, 5, 30, 40), 0.9))
    result._extract_usernames = Mock(return_value=('Opponent', 0.9, None))
    return result


@pytest.fixture
def jpeg():
    return cv2.imencode('.jpg', np.zeros((60, 200, 3), dtype=np.uint8))[1].tobytes()


def test_first_ten_seconds_are_eligible(processor, jpeg):
    assert processor.process_frame(jpeg, 0, 'vod', 'chunk')['username'] == 'Opponent'


def test_failed_ocr_does_not_consume_matchup_interval(processor, jpeg):
    processor._extract_usernames.side_effect = [(None, 0.0, None), ('Opponent', 0.9, None)]
    assert processor.process_frame(jpeg, 20, 'vod', 'chunk') is None
    assert processor.process_frame(jpeg, 22, 'vod', 'chunk')['username'] == 'Opponent'
    assert processor.process_frame(jpeg, 24, 'vod', 'chunk') is None


def test_custom_edge_actually_limits_ocr_input(processor, jpeg):
    result = processor.process_frame(jpeg, 20, 'vod', 'chunk')
    assert result['truncated']
    assert processor._extract_usernames.call_args.args[0].shape[1] == 130


def test_inverted_crop_is_empty_instead_of_full_frame(processor):
    frame = np.zeros((60, 200, 3), dtype=np.uint8)
    assert processor._crop(frame, (150, 0, 30, 30), 100).size == 0


def test_blank_images_do_not_match_masked_templates():
    from pathlib import Path
    templates = str(Path(__file__).resolve().parent.parent / 'templates')
    frame = np.zeros((100, 400, 3), dtype=np.uint8)
    assert EmblemDetector(templates).detect_emblem(frame)[0] is None
    assert RightEdgeDetector(templates).detect_right_edge(frame)[0] is None


def test_continuously_visible_matchup_is_saved_once(processor, jpeg):
    assert processor.process_frame(jpeg, 20, 'vod', 'chunk')
    assert processor.process_frame(jpeg, 32, 'vod', 'chunk') is None
    processor._detect_emblem.return_value = (None, None, 0.0)
    assert processor.process_frame(jpeg, 34, 'vod', 'chunk') is None
    processor._detect_emblem.return_value = ('gold', (0, 5, 30, 40), 0.9)
    assert processor.process_frame(jpeg, 40, 'vod', 'chunk')


def test_ocr_failure_propagates_instead_of_becoming_no_match(processor, jpeg):
    processor._extract_usernames.side_effect = RuntimeError('inference failed')
    with pytest.raises(RuntimeError, match='inference failed'):
        processor.process_frame(jpeg, 20, 'vod', 'chunk')


def test_invalid_jpeg_is_a_processing_error(processor):
    with pytest.raises(ValueError, match='decode'):
        processor.process_frame(b'invalid image', 20, 'vod', 'chunk')


def test_paddle_prediction_failure_is_not_empty_ocr(processor):
    processor.reader = Mock()
    processor.reader.predict.side_effect = RuntimeError('inference failed')
    with pytest.raises(RuntimeError, match='inference failed'):
        FrameProcessor._extract_usernames(processor, np.zeros((60, 200, 3), dtype=np.uint8))


def test_empty_crop_is_rejected_before_inference(processor):
    processor.reader = Mock()
    result = FrameProcessor._extract_usernames(processor, np.zeros((60, 0, 3), dtype=np.uint8))
    assert result[0] is None
    processor.reader.predict.assert_not_called()
