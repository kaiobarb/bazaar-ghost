"""Streamlink adapter for public Bilibili UGC parts; built-in support is live-only."""

from pathlib import Path
import re
import sys
from typing import Iterator, Tuple

from streamlink.plugin import Plugin, pluginmatcher
from streamlink.stream.http import HTTPStream

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from bilibili_source import video_renditions


@pluginmatcher(re.compile(r'https://www\.bilibili\.com/video/(?P<bvid>BV[A-Za-z0-9]{10})/\?cid=(?P<cid>[1-9][0-9]*)$'))
class BazaarBilibili(Plugin):
    def _get_streams(self) -> Iterator[Tuple[str, HTTPStream]]:
        media = video_renditions(f'{self.match["bvid"]}:{self.match["cid"]}')
        for video in media['videos']:
            yield f'{video["height"]}p', HTTPStream(self.session, video['url'], headers=media['headers'])


__plugin__ = BazaarBilibili
