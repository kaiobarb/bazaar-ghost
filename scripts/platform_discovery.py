"""Bounded public discovery feeds; extractor failures never mean an empty feed."""

import html
import json
import re
import subprocess
from typing import Any, Dict, List
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from catalog_youtube import channel_page


def bazaar_title(title: str) -> bool:
    """Use titles to nominate candidates; full metadata is checked before cataloging."""
    return bool(re.search(r'\bbazaar\b|大巴扎', html.unescape(re.sub(r'<[^>]*>', '', title)), re.I))


def extract_page(url: str, start: int = 1, limit: int = 20) -> Dict[str, Any]:
    """Call the maintained extractor with a bounded playlist and no user config."""
    result = subprocess.run([
        'yt-dlp', '--ignore-config', '--flat-playlist', '--dump-single-json',
        '--playlist-start', str(start), '--playlist-end', str(start + limit - 1),
        '--socket-timeout', '20', '--retries', '1', url,
    ], capture_output=True, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError('Public feed extraction failed; retry required')
    return json.loads(result.stdout)


def bilibili_api(path: str, params: Dict[str, Any]) -> Dict[str, Any]:
    """Only public identity and discovery endpoints; no account cookies or bypasses."""
    if path not in ('/x/web-interface/search/type', '/x/web-interface/card'):
        raise ValueError('Unsupported discovery endpoint')
    request = Request('https://api.bilibili.com' + path + '?' + urlencode(params), headers={
        'User-Agent': 'BazaarGhost/1.0', 'Referer': 'https://www.bilibili.com/',
    })
    with urlopen(request, timeout=30) as response:
        data = response.read(2_000_001)
    if len(data) > 2_000_000:
        raise ValueError('Discovery response too large')
    result = json.loads(data)
    if result.get('code') != 0:
        raise RuntimeError(f'Bilibili public API rejected request ({result.get("code")})')
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


def account_page(source: str, identity: str, tab: str, start: int, limit: int = 20) -> List[str]:
    """Poll creator catalogs. Bilibili WBI/anti-bot failures remain retryable errors."""
    if source == 'youtube':
        page = channel_page(identity, start, limit, tab)
        pattern = r'[A-Za-z0-9_-]{11}'
    else:
        if not re.fullmatch(r'[1-9][0-9]*', identity):
            raise ValueError('Expected an immutable Bilibili uploader UID')
        page = extract_page(f'https://space.bilibili.com/{identity}/video', start, limit)
        pattern = r'BV[A-Za-z0-9]{10}'
    return [e['id'] for e in page.get('entries', []) if e and re.fullmatch(pattern, e.get('id', ''))]
