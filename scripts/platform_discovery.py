"""Bounded public discovery feeds; extractor failures never mean an empty feed."""

import json
import re
import subprocess
from typing import Any, Dict, List
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from catalog_youtube import channel_page
from extraction_errors import ExtractionError, extraction_error, provider_api_error, safe_error_category


from game_evidence import bazaar_title


def extract_page(url: str, start: int = 1, limit: int = 20) -> Dict[str, Any]:
    """Call the maintained extractor with a bounded playlist and no user config."""
    try:
        result = subprocess.run([
            'yt-dlp', '--ignore-config', '--flat-playlist', '--dump-single-json',
            '--playlist-start', str(start), '--playlist-end', str(start + limit - 1),
            '--socket-timeout', '20', '--retries', '1', url,
        ], capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise ExtractionError(safe_error_category(error)) from None
    if result.returncode:
        raise extraction_error(result.stderr)
    try:
        page = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ExtractionError('invalid_response') from None
    if not isinstance(page, dict):
        raise ExtractionError('invalid_response')
    return page


def bilibili_api(path: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """Only public identity and discovery endpoints; no account cookies or bypasses."""
    if path not in ('/x/web-interface/search/type', '/x/web-interface/card'):
        raise ValueError('Unsupported discovery endpoint')
    request = Request('https://api.bilibili.com' + path + '?' + urlencode(params), headers={
        'User-Agent': 'BazaarGhost/1.0', 'Referer': 'https://www.bilibili.com/',
    })
    try:
        with urlopen(request, timeout=30) as response:
            data = response.read(2_000_001)
    except (URLError, TimeoutError) as error:
        raise ExtractionError(safe_error_category(error)) from None
    if len(data) > 2_000_000:
        raise ValueError('Discovery response too large')
    try:
        result = json.loads(data)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise ExtractionError('invalid_response') from None
    if not isinstance(result, dict):
        raise ExtractionError('invalid_response')
    if result.get('code') != 0:
        raise provider_api_error(result.get('code'))
    if not isinstance(result.get('data'), dict):
        raise ExtractionError('invalid_response')
    return result['data']


def discover(source: str) -> List[str]:
    """Return recent game candidates, never invent creator identity from a name."""
    if source == 'youtube':
        query = urlencode({'search_query': 'The Bazaar', 'sp': 'CAISAhAB'})
        entries = extract_page('https://www.youtube.com/results?' + query).get('entries', [])
        return list(dict.fromkeys(e['id'] for e in entries if e and
                                 re.fullmatch(r'[A-Za-z0-9_-]{11}', e.get('id', '')) and
                                 bazaar_title(e.get('title') or '')))
    data = bilibili_api('/x/web-interface/search/type', {
        'search_type': 'video', 'keyword': '大巴扎', 'order': 'pubdate', 'page': 1, 'page_size': 20,
    })
    return list(dict.fromkeys(e['bvid'] for e in data.get('result', []) if
                             re.fullmatch(r'BV[A-Za-z0-9]{10}', e.get('bvid', '')) and
                             bazaar_title(e.get('title') or '')))


def account_page(source: str, identity: str, tab: str, start: int, limit: int = 20) -> Dict[str, Any]:
    """Poll creator catalogs. Bilibili WBI/anti-bot failures remain retryable errors."""
    if source == 'youtube':
        page = channel_page(identity, start, limit, tab)
        pattern = r'[A-Za-z0-9_-]{11}'
    else:
        if not re.fullmatch(r'[1-9][0-9]*', identity):
            raise ValueError('Expected an immutable Bilibili uploader UID')
        page = extract_page(f'https://space.bilibili.com/{identity}/video', start, limit)
        pattern = r'BV[A-Za-z0-9]{10}'
    entries = page.get('entries', [])
    return {'ids': [e['id'] for e in entries if e and re.fullmatch(pattern, e.get('id', ''))],
            'inspected': len(entries)}
