"""Finite diagnostics for untrusted provider failures; never retain upstream text."""

import json
import re
import subprocess
from urllib.error import HTTPError, URLError


MESSAGES = {
    'auth_required': 'provider requires human sign-in from this runner',
    'age_restricted': 'age-restricted recording',
    'account_required': 'recording requires account access',
    'http_403': 'provider denied access (HTTP 403)',
    'http_412': 'provider rejected the request precondition (HTTP 412)',
    'http_429': 'provider rate limit (HTTP 429)',
    'http_error': 'HTTP request failed',
    'provider_challenge': 'provider requires a verification challenge',
    'runtime_unavailable': 'JavaScript runtime unavailable',
    'player_challenge': 'player challenge extraction failed',
    'recording_unavailable': 'recording unavailable to this runner',
    'transport_failure': 'provider transport failure',
    'transport_timeout': 'provider request timed out',
    'extractor_runtime_failure': 'extractor runtime failed',
    'extractor_failure': 'unclassified provider extraction failure',
    'invalid_response': 'provider returned an invalid response',
    'provider_api_rejected': 'provider API rejected the request',
    'provider_feed_rejected': 'provider rejected the public feed request',
    'invalid_data': 'data validation failed',
    'runtime_failure': 'operation failed',
    'unexpected_error': 'unexpected operation failure',
}


class ExtractionError(RuntimeError):
    """An allowlisted category and constant message, without stderr or a URL."""

    def __init__(self, category: str):
        if category not in MESSAGES:
            raise ValueError('Unknown extraction error category')
        self.category = category
        super().__init__(f'{category}: {MESSAGES[category]}')


def extraction_error(stderr: str) -> ExtractionError:
    """Inspect extractor stderr only at its boundary; return constant diagnostics."""
    message = stderr.lower().replace('\u2019', "'")
    # Prefer explicit authentication/challenge evidence over a generic HTTP denial.
    categories = (
        (("confirm you're not a bot", 'confirm you are not a bot', 'login required', 'authentication required'), 'auth_required'),
        (('sign in to confirm your age', 'age-restricted'), 'age_restricted'),
        (('private video', 'members-only', 'join this channel', 'premium-only'), 'account_required'),
        (('captcha', 'anti-bot', 'human verification', 'risk control'), 'provider_challenge'),
        (('no supported javascript runtime', 'javascript runtime'), 'runtime_unavailable'),
        (('challenge solving failed', 'signature extraction failed', 'nsig extraction failed'), 'player_challenge'),
    )
    for markers, category in categories:
        if any(marker in message for marker in markers):
            return ExtractionError(category)
    # yt-dlp's Bilibili feed extractor formats HTTP 412 and JSON -401/-352
    # differently. The JSON codes do not describe HTTP status or user credentials.
    if 'request is blocked by server (412)' in message:
        return ExtractionError('http_412')
    if ('request is blocked by server (401)' in message
            or 'request is rejected by server (352)' in message):
        return ExtractionError('provider_feed_rejected')
    status = re.search(r'\bhttp(?:\s+error|\s+status)?[\s:]+(403|412|429)\b', message)
    if status:
        return ExtractionError('http_' + status.group(1))
    categories = (
        (('too many requests',), 'http_429'),
        (('forbidden',), 'http_403'),
        (('precondition failed',), 'http_412'),
        (('video unavailable', 'video has been removed'), 'recording_unavailable'),
        (('timed out', 'timeout'), 'transport_timeout'),
        (('temporary failure', 'unable to download webpage', 'connection reset', 'connection refused'), 'transport_failure'),
        (('traceback (most recent call last)', 'typeerror:', 'keyerror:', 'attributeerror:', 'indexerror:'), 'extractor_runtime_failure'),
    )
    return ExtractionError(next((category for markers, category in categories
                                 if any(marker in message for marker in markers)), 'extractor_failure'))


def provider_api_error(code: object) -> ExtractionError:
    """Known Bilibili JSON rejection codes; arbitrary response values stay private."""
    category = 'provider_feed_rejected' if type(code) is int and code in (-401, -352) else 'provider_api_rejected'
    return ExtractionError(category)


def safe_error_category(error: Exception) -> str:
    """Keep typed diagnostics; never interpret or print an arbitrary exception body."""
    if isinstance(error, ExtractionError):
        return error.category if error.category in MESSAGES else 'unexpected_error'
    if isinstance(error, HTTPError):
        category = f'http_{error.code}' if error.code in (403, 412, 429) else 'http_error'
        # Release the rejected response. An unclosed HTTPError can emit its raw
        # message through a ResourceWarning during later garbage collection.
        error.close()
        return category
    if isinstance(error, (TimeoutError, subprocess.TimeoutExpired)):
        return 'transport_timeout'
    if isinstance(error, URLError):
        return 'transport_failure'
    if isinstance(error, (json.JSONDecodeError, UnicodeError)):
        return 'invalid_response'
    if isinstance(error, OSError):
        return 'extractor_runtime_failure'
    if isinstance(error, ValueError):
        return 'invalid_data'
    if isinstance(error, RuntimeError):
        return 'runtime_failure'
    return 'unexpected_error'
