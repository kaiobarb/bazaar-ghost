"""Tests for username cleaning and validation logic.

Pure unit tests — no OCR or image loading required.
Tests the _clean_username method which enforces Bazaar username rules:
  - 2-13 characters
  - Starts with letter or number
  - Only alphanumeric, underscore, dash, dot allowed
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

from frame_processor import FrameProcessor


@pytest.fixture(scope="module")
def clean_username():
    """Get the _clean_username method without full FrameProcessor init."""

    # _clean_username is a pure function that only uses self for nothing,
    # but it's an instance method. Create a minimal mock.
    class Stub:
        def _clean_username(self, text):
            return FrameProcessor._clean_username(self, text)

    return Stub()._clean_username


class TestValidUsernames:
    """Usernames that should pass through cleaning unchanged."""

    @pytest.mark.parametrize(
        "username",
        [
            "nl_Kripp",
            "Tactique",
            "user1234",
            "a-b-c-d",
            "name.dot",
            "ALLCAPS1234",
            "four",
            "ab",
            "a" * 13,
        ],
    )
    def test_valid_username_passes(self, clean_username, username):
        assert clean_username(username) == username


class TestInvalidUsernames:
    """Usernames that should be rejected (return None)."""

    @pytest.mark.parametrize(
        "username,reason",
        [
            ("x", "too short (1 char)"),
            ("", "empty string"),
            ("a" * 14, "too long (14 chars)"),
            ("a" * 25, "too long (25 chars)"),
            (".leading_dot", "starts with dot"),
            ("-leading_dash", "starts with dash"),
            ("_leading_under", "starts with underscore"),
        ],
    )
    def test_invalid_username_rejected(self, clean_username, username, reason):
        assert clean_username(username) is None, f"Should reject: {reason}"

    def test_none_input(self, clean_username):
        assert clean_username(None) is None

    def test_empty_string(self, clean_username):
        assert clean_username("") is None


class TestSpecialCharacterStripping:
    """Characters outside the allowlist are stripped before validation."""

    @pytest.mark.parametrize(
        "input_text,expected",
        [
            ("user!name", "username"),
            ("user@#$%name", "username"),
            ("valid_user!", "valid_user"),
            ("name (extra)", "nameextra"),
            ("user name", "username"),
            ("café_user", "caf_user"),
        ],
    )
    def test_special_chars_stripped(self, clean_username, input_text, expected):
        result = clean_username(input_text)
        if (
            expected
            and len(expected) >= 2
            and len(expected) <= 13
            and expected[0].isalnum()
        ):
            assert result == expected
        else:
            assert result is None


class TestEdgeCases:
    """Boundary conditions and edge cases."""

    def test_exactly_2_chars(self, clean_username):
        assert clean_username("ab") == "ab"

    def test_exactly_13_chars(self, clean_username):
        name = "a" * 13
        assert clean_username(name) == name

    def test_14_chars_rejected(self, clean_username):
        assert clean_username("a" * 14) is None

    def test_1_char_rejected(self, clean_username):
        assert clean_username("a") is None

    def test_digits_only(self, clean_username):
        assert clean_username("1234") == "1234"

    def test_two_digit_username(self, clean_username):
        assert clean_username("42") == "42"

    def test_preserves_case(self, clean_username):
        assert clean_username("MixedCase123") == "MixedCase123"

    def test_dots_and_dashes(self, clean_username):
        assert clean_username("user.name-hr") == "user.name-hr"
