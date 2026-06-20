"""Natural-language search: embed the query, then query LanceDB."""
from __future__ import annotations

import logging
from typing import List

import config
import embeddings
import intent
import vector_store
from models import SearchResult

log = logging.getLogger(__name__)

# Specific scopes map to the modalities they include. `all`/`any` blend across
# kinds; `auto` asks the LLM to pick a kind (falling back to a blend).
SCOPE_MODALITIES = {
    "documents": {"text", "code", "pdf", "docx"},
    "images": {"image"},
    "audio": {"audio"},
    "video": {"video"},
}

# Kinds blended via reciprocal-rank fusion for `all` / `any`, so media is fairly
# represented despite the text/media modality gap.
_BLEND_KINDS = [
    {"text", "code", "pdf", "docx"},
    {"image"},
    {"audio"},
    {"video"},
]


def _search_blended(vector: List[float], limit: int) -> List[SearchResult]:
    """Reciprocal-rank fusion across kinds so every modality gets a fair shot."""
    k = 60
    scored: dict = {}
    items: dict = {}
    for modalities in _BLEND_KINDS:
        hits = vector_store.search_chunks(vector, limit=limit, modalities=modalities)
        for rank, hit in enumerate(hits):
            key = (hit.file_path, hit.page_number, hit.chunk_index)
            scored[key] = scored.get(key, 0.0) + 1.0 / (k + rank + 1)
            items[key] = hit
    order = sorted(scored, key=lambda key: (scored[key], items[key].score or 0.0), reverse=True)
    return [items[key] for key in order[:limit]]


def run_search(query: str, limit: int = 10, scope: str = "auto") -> dict:
    query = query.strip()
    if not query:
        return {"status": "error", "message": "Empty query"}

    scope = (scope or "auto").lower()
    detected = None
    resolved = scope
    if scope == "auto":
        # Let the LLM decide the kind; "any" => fair blend across everything.
        detected = intent.classify_scope(query)
        resolved = detected

    if resolved not in ("all", "any") and resolved not in SCOPE_MODALITIES:
        return {"status": "error", "message": f"Unknown scope '{resolved}'"}

    model = config.resolve_embedding_model()          # validate configured model
    vector_store.check_index_compatibility(model, config.EMBEDDING_DIMENSIONS)
    vector = embeddings.embed_text(query, task_type=embeddings.TASK_QUERY)

    if resolved in ("all", "any"):
        results: List[SearchResult] = _search_blended(vector, limit)
    else:
        results = vector_store.search_chunks(
            vector, limit=limit, modalities=SCOPE_MODALITIES[resolved]
        )

    return {
        "status": "success",
        "query": query,
        "scope": scope,
        "resolved_scope": resolved,
        "detected_scope": detected,
        "results": [r.model_dump() for r in results],
    }
