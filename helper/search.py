"""Natural-language search: embed the query, then query LanceDB."""
from __future__ import annotations

import logging
from typing import List

import config
import embeddings
import vector_store
from models import SearchResult

log = logging.getLogger(__name__)


def run_search(query: str, limit: int = 10) -> dict:
    query = query.strip()
    if not query:
        return {"status": "error", "message": "Empty query"}

    model = config.resolve_embedding_model()          # validate configured model
    vector_store.check_index_compatibility(model, config.EMBEDDING_DIMENSIONS)

    vector = embeddings.embed_text(query, task_type=embeddings.TASK_QUERY)
    results: List[SearchResult] = vector_store.search_chunks(vector, limit=limit)
    return {
        "status": "success",
        "query": query,
        "results": [r.model_dump() for r in results],
    }
