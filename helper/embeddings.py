"""Gemini Embedding 2 integration.

Embeds documents and queries with the same model. Handles batching, retries
with exponential backoff, and L2-normalizes vectors (recommended by Google for
output dimensionalities other than 3072).
"""
from __future__ import annotations

import logging
import math
import os
import time
from typing import Callable, List, TypeVar

import config

T = TypeVar("T")

log = logging.getLogger(__name__)

# Task types tell the model whether text is a stored document or a query — both
# use the *same* model, which is what good asymmetric retrieval wants.
TASK_DOCUMENT = "RETRIEVAL_DOCUMENT"
TASK_QUERY = "RETRIEVAL_QUERY"

_client = None


class QuotaExceededError(RuntimeError):
    """Raised when the Gemini API rejects a call for quota/rate-limit reasons.

    Maps to HTTP 429 / RESOURCE_EXHAUSTED. Surfaced distinctly so the app can
    tell the user they've hit their API limit rather than showing a generic
    failure, and so indexing aborts immediately instead of hammering a quota
    that is already spent.
    """


class NetworkUnavailableError(RuntimeError):
    """Raised when Gemini cannot be reached due to an offline/network failure."""


def is_quota_error(exc: Exception) -> bool:
    """True when `exc` looks like a Gemini quota / rate-limit (HTTP 429) error."""
    if isinstance(exc, QuotaExceededError):
        return True

    for source in (exc, getattr(exc, "response", None)):
        if source is None:
            continue
        for attr in ("code", "status_code"):
            code = getattr(source, attr, None)
            if code is None:
                continue
            try:
                if int(code) == 429:
                    return True
            except (TypeError, ValueError):
                if str(code).strip() == "429":
                    return True

    text = str(exc).lower()
    # Keep these markers specific to actual quota / rate-limit failures. A bare
    # "quota" substring is too broad and can misclassify unrelated messages.
    return any(marker in text for marker in (
        "resource_exhausted",
        "too many requests",
        "http 429",
        "http/1.1 429",
        "status_code=429",
        "code=429",
        "'code': 429",
        '"code": 429',
        "quota exceeded",
        "exceeded your current quota",
        "rate limit exceeded",
        "rate-limit exceeded",
    ))


def is_network_error(exc: Exception) -> bool:
    """True when `exc` looks like an offline / network-unreachable failure."""
    if isinstance(exc, NetworkUnavailableError):
        return True

    text = f"{type(exc).__name__} {exc}".lower()
    network_markers = (
        "connecterror",
        "connectionerror",
        "connection error",
        "connection refused",
        "connection reset",
        "connection aborted",
        "connection timed out",
        "network is unreachable",
        "network unreachable",
        "no internet",
        "offline",
        "temporary failure in name resolution",
        "name resolution",
        "nodename nor servname",
        "name or service not known",
        "gaierror",
        "failed to establish a new connection",
        "max retries exceeded",
        "could not resolve",
        "dns",
    )
    return any(marker in text for marker in network_markers)


def _get_client():
    """Lazily build the genai client so offline commands work without a key."""
    global _client
    if _client is None:
        if not config.GEMINI_API_KEY:
            raise RuntimeError(
                "GEMINI_API_KEY is not set. Add it to your .env or environment."
            )
        from google import genai
        from google.genai import types
        _client = genai.Client(
            api_key=config.GEMINI_API_KEY,
            http_options=types.HttpOptions(timeout=config.REQUEST_TIMEOUT_MS),
        )
    return _client


def _normalize(vec: List[float]) -> List[float]:
    norm = math.sqrt(sum(x * x for x in vec))
    if norm == 0.0:
        return vec
    return [x / norm for x in vec]


def _with_retries(fn: Callable[[], T], label: str, attempts: int = config.EMBED_MAX_ATTEMPTS) -> T:
    """Run `fn`, retrying transient failures with exponential backoff."""
    last_err: Exception | None = None
    for attempt in range(attempts):
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 - retry any transient failure
            # A quota / rate-limit error won't clear in the few seconds we'd
            # back off for, and retrying just burns more of an exhausted quota.
            # Fail fast with a typed error so the app can tell the user clearly.
            if is_quota_error(exc):
                log.warning("%s hit a Gemini quota / rate limit: %s", label, exc)
                raise QuotaExceededError(
                    "Gemini API quota or rate limit exceeded (HTTP 429)."
                ) from exc
            # Offline / DNS / unreachable errors also should not make the app
            # look frozen for minutes. Surface them so the app can fall back to
            # local filename/text search.
            if is_network_error(exc):
                log.warning("%s could not reach Gemini: %s", label, exc)
                raise NetworkUnavailableError(
                    "Cannot reach Gemini. Check your internet connection and try again."
                ) from exc
            last_err = exc
            if attempt < attempts - 1:
                wait = min(2 ** attempt, 30)
                log.warning("%s attempt %d failed (%s); retrying in %ss",
                            label, attempt + 1, exc, wait)
                time.sleep(wait)
    raise RuntimeError(f"{label} failed after retries: {last_err}")


def _embed_request(texts: List[str], task_type: str) -> List[List[float]]:
    """One embedding API call for a text batch, with retries on transient errors."""
    from google.genai import types

    client = _get_client()
    cfg = types.EmbedContentConfig(
        task_type=task_type,
        output_dimensionality=config.EMBEDDING_DIMENSIONS,
    )

    def _call() -> List[List[float]]:
        resp = client.models.embed_content(
            model=config.resolve_embedding_model(),
            contents=texts,
            config=cfg,
        )
        return [list(e.values) for e in resp.embeddings]

    return _with_retries(_call, "Embedding")


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


def _wait_until_active(client, file, timeout: int = 120):
    """Poll an uploaded file until it leaves the PROCESSING state (best-effort)."""
    waited = 0
    while waited < timeout:
        state = getattr(file.state, "name", str(file.state)) if file.state else "ACTIVE"
        if state != "PROCESSING":
            return file
        time.sleep(2)
        waited += 2
        file = _with_retries(
            lambda: client.files.get(name=file.name),
            "Media upload status check",
        )
    return file


def embed_media_file(path: str, mime_type: str, task_type: str = TASK_DOCUMENT) -> List[float]:
    """Embed one media segment (image/audio/video) into the shared vector space.

    Small files are sent inline; larger ones go through the Files API. Returns a
    single normalized vector — the same space and dimensionality as text.
    """
    from google.genai import types

    client = _get_client()
    cfg = types.EmbedContentConfig(
        task_type=task_type,
        output_dimensionality=config.EMBEDDING_DIMENSIONS,
    )

    def _embed_part(part) -> List[float]:
        resp = client.models.embed_content(
            model=config.resolve_embedding_model(),
            contents=[part],
            config=cfg,
        )
        return _normalize(list(resp.embeddings[0].values))

    if os.path.getsize(path) <= config.MEDIA_INLINE_MAX_BYTES:
        with open(path, "rb") as fh:
            data = fh.read()
        part = types.Part.from_bytes(data=data, mime_type=mime_type)
        return _with_retries(lambda: _embed_part(part), "Media embedding")

    # Large segment → upload via the Files API, embed by reference, then clean up.
    uploaded = _with_retries(
        lambda: client.files.upload(file=path),
        "Media upload",
    )
    try:
        uploaded = _wait_until_active(client, uploaded)
        part = types.Part.from_uri(file_uri=uploaded.uri, mime_type=mime_type)
        return _with_retries(lambda: _embed_part(part), "Media embedding")
    finally:
        try:
            client.files.delete(name=uploaded.name)
        except Exception:  # noqa: BLE001 - cleanup is best-effort
            pass
