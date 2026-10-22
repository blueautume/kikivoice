"""Small local text policy for public profile fields, not voice moderation.

Operators can add literal phrases through PUBLIC_CONTENT_BLOCKLIST (one phrase
per line or comma separated). No user-submitted text is sent to a third party or
written to a rejection log. This deliberately does not claim semantic coverage.
"""
import re
import unicodedata

from fastapi import HTTPException

DEFAULT_BLOCKED_PHRASES = ("操你妈", "傻逼", "色情交易", "未成年裸聊", "裸聊交易")


def normalize(value):
    return "".join(char for char in unicodedata.normalize("NFKC", value).casefold()
                   if not char.isspace() and not unicodedata.category(char).startswith(("P", "Z", "C")))


class PublicTextPolicy:
    def __init__(self, extra=""):
        if not isinstance(extra, str) or len(extra.encode("utf-8")) > 32768:
            raise RuntimeError("PUBLIC_CONTENT_BLOCKLIST must contain at most 32768 UTF-8 bytes")
        phrases = DEFAULT_BLOCKED_PHRASES + tuple(re.split(r"[,，\n\r]", extra))
        self.phrases = tuple({clean for phrase in phrases if (clean := normalize(phrase.strip()))})

    def check_profile(self, *, name=None, bio=None):
        for value in (name, bio):
            if value is not None and (any(unicodedata.category(char) in {"Cf", "Cs"} for char in value)
                                      or any(phrase in normalize(value) for phrase in self.phrases)):
                raise HTTPException(422, "昵称或简介包含不适合公开展示的内容，请修改")
