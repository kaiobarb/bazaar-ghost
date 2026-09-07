"""Shared coarse admission rule for discovery and catalog normalization."""

import html
import re


def bazaar_title(title):
    text = html.unescape(re.sub(r'<[^>]*>', '', title))
    return bool(re.search(r'\bbazaar\b|大巴扎', text, re.I))


def bazaar_evidence(title, tags=()):
    return bazaar_title(title) or any(str(tag).casefold() in ('the bazaar', 'thebazaar', '大巴扎') for tag in tags)
