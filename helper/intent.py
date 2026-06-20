"""Classify a search query to the kind of file the user wants.

Hybrid, cheapest-first:
  1. Keyword cues (e.g. "photo", "pdf", "clip") pick the kind with NO API call.
  2. Only when the query has no clear cue do we fall back to a small generative
     model to read the intent.

Returns one of documents / images / audio / video, or "any" when still unclear
(the caller then blends across all kinds).
"""
from __future__ import annotations

import enum
import logging
import re
from typing import Optional

import config
import embeddings  # reuse its lazily-built genai client

log = logging.getLogger(__name__)

VALID = ("documents", "images", "audio", "video", "any")

# Unambiguous cue words per kind. Words that fit more than one kind (e.g.
# "recording", which may be audio or video) are deliberately omitted so those
# queries fall through to the model rather than guessing.
KEYWORDS = {
    "images": {
        "photo", "photos", "picture", "pictures", "pic", "pics", "image",
        "images", "screenshot", "screenshots", "selfie", "selfies", "wallpaper",
        "png", "jpg", "jpeg",
    },
    "audio": {
        "audio", "song", "songs", "music", "mp3", "podcast", "podcasts",
        "voicemail", "audiobook", "soundtrack",
    },
    "video": {
        "video", "videos", "clip", "clips", "movie", "movies", "footage",
        "mp4", "film", "films", "episode", "episodes", "reel", "reels",
    },
    "documents": {
        "pdf", "pdfs", "document", "documents", "docx", "spreadsheet", "excel",
        "csv", "slides", "presentation", "powerpoint", "resume", "invoice",
        "essay", "assignment", "report",
    },
}


class _Kind(enum.Enum):
    DOCUMENTS = "documents"
    IMAGES = "images"
    AUDIO = "audio"
    VIDEO = "video"
    ANY = "any"


_INSTRUCTION = (
    "You route a file-search query to the kind of file the user is looking for.\n"
    "- images: photos, pictures, screenshots, or visual scenes (e.g. 'sunset over the ocean', 'my dog')\n"
    "- audio: music, songs, recordings, podcasts, voice notes\n"
    "- video: clips, footage, movies, episodes, screen recordings\n"
    "- documents: text, PDFs, notes, reports, code, spreadsheets, assignments\n"
    "- any: the query does not clearly imply one kind\n"
    "Pick the single best kind. Query: "
)


def _keyword_scope(query: str) -> Optional[str]:
    """Return a kind if exactly one kind's cue words appear; else None."""
    words = set(re.findall(r"[a-z0-9]+", query.lower()))
    matched = {kind for kind, cues in KEYWORDS.items() if words & cues}
    return matched.pop() if len(matched) == 1 else None


def _llm_scope(query: str) -> str:
    from google.genai import types
    client = embeddings._get_client()
    resp = client.models.generate_content(
        model=config.GENERATION_MODEL,
        contents=_INSTRUCTION + query,
        config=types.GenerateContentConfig(
            temperature=0,
            response_mime_type="text/x.enum",
            response_schema=_Kind,
        ),
    )
    text = (resp.text or "").strip().strip('"').lower()
    for kind in VALID:
        if kind in text:
            return kind
    return "any"


def classify_scope(query: str) -> str:
    """Keyword fast-path first (no API); model fallback for unclear queries."""
    query = (query or "").strip()
    if not query:
        return "any"

    keyword = _keyword_scope(query)
    if keyword is not None:
        return keyword

    try:
        return _llm_scope(query)
    except Exception as exc:  # noqa: BLE001 - never let detection break search
        log.warning("intent classification failed (%s); falling back to blend", exc)
        return "any"
