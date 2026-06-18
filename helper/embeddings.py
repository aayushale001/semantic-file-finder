"""Gemini Embedding 2 integration.

Embeds documents and queries with the same model. Handles batching, retries
with exponential backoff, and L2-normalizes vectors (recommended by Google for
output dimensionalities other than 3072).
"""
from __future__ import annotations

import logging
import math
import time
from typing import List

import config

log = logging.getLogger(__name__)

# Task types tell the model whether text is a stored document or a query — both
# use the *same* model, which is what good asymmetric retrieval wants.
TASK_DOCUMENT = "RETRIEVAL_DOCUMENT"
TASK_QUERY = "RETRIEVAL_QUERY"

_client = None


def _get_client():
    """Lazily build the genai client so offline commands work without a key."""
    global _client
    if _client is None:
        if not config.GEMINI_API_KEY:
            raise RuntimeError(
                "GEMINI_API_KEY is not set. Add it to your .env or environment."
            )
        from google import genai
        _client = genai.Client(api_key=config.GEMINI_API_KEY)
    return _client


def _normalize(vec: List[float]) -> List[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    if norm == 0.0:
        return vec
    return [x / norm for x in vec]


def _embed_request(texts: List[str], task_type: str) -> List[List[float]]:
    """One embedding API call for a batch, with retries on transient errors."""
    from google.genai import types

    client = _get_client()
    cfg = types.EmbedContentConfig(
        task_type=task_type,
        output_dimensionality=config.EMBEDDING_DIMENSIONS,
    )

    last_err: Exception | None = None
    for attempt in range(5):
        try:
            resp = client.models.embed_content(
                model=config.resolve_embedding_model(),
                contents=texts,
                config=cfg,
            )
            return [list(e.values) for e in resp.embeddings]
        except Exception as exc:  # noqa: BLE001 - retry any transient failure
            last_err = exc
            wait = min(2 ** attempt, 30)
            log.warning("Embedding attempt %d failed (%s); retrying in %ss",
                        attempt + 1, exc, wait)
            time.sleep(wait)
    raise RuntimeError(f"Embedding failed after retries: {last_err}")


def embed_batch(texts: List[str], task_type: str = TASK_DOCUMENT) -> List[List[float]]:
    """Embed a list of strings, returning one normalized vector per string."""
    if not texts:
        return []
    out: List[List[float]] = []
    batch = max(1, config.EMBEDDING_BATCH_SIZE)
    for i in range(0, len(texts), batch):
        vectors = _embed_request(texts[i:i + batch], task_type)
        out.extend(_normalize(v) for v in vectors)
    return out


def embed_text(text: str, task_type: str = TASK_DOCUMENT) -> List[float]:
    """Embed a single string. Use TASK_QUERY for search queries."""
    return embed_batch([text], task_type)[0]
