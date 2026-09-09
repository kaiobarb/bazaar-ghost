"""Strict day readings and native intro/clock fixtures from a reproduced OCR error."""
import logging
from pathlib import Path
from unittest.mock import Mock

import cv2
import numpy as np
import pytest

from frame_processor import FrameProcessor


@pytest.fixture
def reader():
    value = FrameProcessor.__new__(FrameProcessor)
    value.logger = logging.getLogger('test.igd')
    value.reader = Mock()
    return value


def read(reader, texts, scores):
    reader.reader.predict.return_value = [{'rec_texts': texts, 'rec_scores': scores}]
    return reader.extract_igd(np.zeros((12, 12, 3), dtype=np.uint8))


@pytest.mark.parametrize('text,expected', [('1', 1), ('9', 9), ('11', 11), ('20', 20), (' 11 ', 11)])
def test_one_whole_day_token_at_confidence_boundary(reader, text, expected):
    assert read(reader, [text], [0.9]) == expected


@pytest.mark.parametrize('text', ['0', '21', '011', '-11', '+11', '1.1', '1 1', '1I', 'I1', 'day11', '11th', '١١', '１１', ''])
def test_characters_are_never_stripped_to_manufacture_a_day(reader, text):
    assert read(reader, [text], [0.99]) is None


@pytest.mark.parametrize('score', [0.8999, float('nan'), float('inf'), -float('inf'), True, None, '0.99'])
def test_invalid_or_low_confidence_is_unknown(reader, score):
    assert read(reader, ['11'], [score]) is None


@pytest.mark.parametrize('texts,scores', [
    (['1', '1'], [0.99, 0.98]), (['11', '5'], [0.999, 0.99]),
    (['11', 'DAY'], [0.99, 0.95]), (['11', '5'], [0.99]),
    (['11'], [0.99, 0.98]), ([11], [0.99]),
])
def test_multiple_qualifying_boxes_or_malformed_results_are_ambiguous(reader, texts, scores):
    assert read(reader, texts, scores) is None


def test_low_confidence_noise_does_not_override_one_valid_day(reader):
    assert read(reader, ['noise', '11'], [0.5, np.float32(0.99)]) == 11


@pytest.fixture(scope='module')
def native_processor():
    templates = str(Path(__file__).resolve().parent.parent / 'templates')
    value = FrameProcessor({'emblem_detection': {'enabled': True, 'templates_dir': templates, 'template_threshold': 0.5},
        'right_edge_detection': {'enabled': False}, 'ocr': {'confidence_threshold': 0.5}}, quality='480p')
    assert value.emblem_visible is False
    return value


def native_frame(second):
    path = Path(__file__).parent / 'fixtures' / 'igd' / f'twitch-2863728070-{second}.jpg'
    frame = cv2.imread(str(path))
    assert frame is not None and frame.shape == (192, 664, 3)
    # Exact profile2 nameplate geometry inside the native480 combined MJPEG.
    nameplate = cv2.imencode('.jpg', frame[133:192, 365:664])[1].tobytes()
    return frame, nameplate


def test_native_intro_is_visible_even_when_duplicate_matchup_returns_none(native_processor):
    _, nameplate = native_frame(2174)
    native_processor.matchup_active = True
    assert native_processor.process_frame(nameplate, 2174, '2863728070', 'fixture') is None
    assert native_processor.emblem_visible is True


def test_native_visible_clock_clears_overlay_and_reads_eleven(native_processor):
    frame, nameplate = native_frame(2178)
    assert native_processor.process_frame(nameplate, 2178, '2863728070', 'fixture') is None
    assert native_processor.emblem_visible is False
    assert native_processor.extract_igd(frame[:12, :12]) == 11
