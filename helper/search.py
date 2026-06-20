"""Natural-language search: embed the query, then query LanceDB."""
from __future__ import annotations

import logging
from typing import List

import config
import embeddings
import vector_store
from models import SearchResult

log = logging.getLogger(__name__)

# Search scopes map to the set of modalities they include. `all` => no filter.
SCOPE_MODALITIES = {
    "all": None,
    "documents": {"text", "code", "pdf", "docx"},
    "images": {"image"},
    "audio": {"audio"},
    "video": {"video"},
}


def run_search(query: str, limit: int = 10, scope: str = "all") -> dict:
    query = query.strip()
    if not query:
        return {"status": "error", "message": "Empty query"}

    scope = (scope or "all").lower()
    if scope not in SCOPE_MODALITIES:
        return {"status": "error", "message": f"Unknown scope '{scope}'"}
    modalities = SCOPE_MODALITIES[scope]

    model = config.resolve_embedding_model()          # validate configured model
    vector_store.check_index_compatibility(model, config.EMBEDDING_DIMENSIONS)

    vector = embeddings.embed_text(query, task_type=embeddings.TASK_QUERY)
    results: List[SearchResult] = vector_store.search_chunks(
        vector, limit=limit, modalities=modalities
    )
    return {
        "status": "success",
        "query": query,
        "scope": scope,
        "results": [r.model_dump() for r in results],
    }
