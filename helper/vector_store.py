"""LanceDB-backed vector store for chunk rows + metadata."""
from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import List, Optional

import pyarrow as pa

import config
from models import ChunkRecord, SearchResult

log = logging.getLogger(__name__)


class IndexMismatchError(RuntimeError):
    """Raised when the index's embedding model differs from the configured one."""


def get_db():
    """Connect to (creating if needed) the local LanceDB at config.DB_PATH."""
    import lancedb
    config.ensure_dirs()
    return lancedb.connect(str(config.DB_PATH))


def _schema() -> pa.Schema:
    return pa.schema([
        pa.field("chunk_id", pa.string()),
        pa.field("file_id", pa.string()),
        pa.field("file_path", pa.string()),
        pa.field("file_name", pa.string()),
        pa.field("file_extension", pa.string()),
        pa.field("modality", pa.string()),
        pa.field("content_preview", pa.string()),
        pa.field("full_text", pa.string()),
        pa.field("page_number", pa.int64()),
        pa.field("chunk_index", pa.int64()),
        pa.field("start_char", pa.int64()),
        pa.field("end_char", pa.int64()),
        pa.field("file_size_bytes", pa.int64()),
        pa.field("file_modified_at", pa.string()),
        pa.field("file_hash", pa.string()),
        pa.field("embedding", pa.list_(pa.float32(), config.EMBEDDING_DIMENSIONS)),
        pa.field("indexed_at", pa.string()),
    ])


def ensure_table():
    """Return the chunks table, creating an empty one if it does not exist."""
    db = get_db()
    if config.TABLE_NAME not in db.table_names():
        db.create_table(config.TABLE_NAME, schema=_schema())
    return db.open_table(config.TABLE_NAME)


def get_table():
    """Return the chunks table, or None if it has not been created yet."""
    db = get_db()
    if config.TABLE_NAME not in db.table_names():
        return None
    return db.open_table(config.TABLE_NAME)


def add_chunks(chunks: List[ChunkRecord]) -> int:
    if not chunks:
        return 0
    tbl = ensure_table()
    tbl.add([c.model_dump() for c in chunks])
    return len(chunks)


def delete_file(file_path: str) -> None:
    """Remove all chunks belonging to a given file path (for re-indexing)."""
    tbl = get_table()
    if tbl is None:
        return
    safe = file_path.replace("'", "''")
    tbl.delete(f"file_path = '{safe}'")


def _column_values(tbl, column: str) -> list:
    """Read a single column cheaply, with a fallback for older LanceDB."""
    try:
        return tbl.to_lance().to_table(columns=[column]).column(column).to_pylist()
    except Exception:
        try:
            return tbl.to_arrow().column(column).to_pylist()
        except Exception:
            return []


def get_indexed_file_ids() -> set:
    """Set of file_ids already present — used to skip unchanged files."""
    tbl = get_table()
    if tbl is None:
        return set()
    return set(_column_values(tbl, "file_id"))


def search_chunks(query_embedding: List[float], limit: int = 10) -> List[SearchResult]:
    tbl = get_table()
    if tbl is None:
        return []
    # NB: no .select() projection — LanceDB is deprecating auto-inclusion of the
    # `_distance` score when columns are projected, and we rely on that score.
    rows = (
        tbl.search(query_embedding)
        .metric("cosine")
        .limit(limit)
        .to_list()
    )
    results: List[SearchResult] = []
    for r in rows:
        dist = r.get("_distance")
        # cosine distance -> similarity (vectors are normalized at embed time)
        score: Optional[float] = None if dist is None else round(1.0 - float(dist), 4)
        results.append(SearchResult(
            file_name=r["file_name"],
            file_path=r["file_path"],
            file_extension=r["file_extension"],
            content_preview=r["content_preview"],
            page_number=r.get("page_number"),
            chunk_index=r["chunk_index"],
            score=score,
        ))
    return results


def reset_index() -> None:
    """Drop and recreate the chunks table, and clear index metadata."""
    db = get_db()
    if config.TABLE_NAME in db.table_names():
        db.drop_table(config.TABLE_NAME)
    ensure_table()
    delete_index_metadata()


# --- index metadata (embedding provenance) -----------------------------------
# Persisted next to the index so we can refuse to mix embeddings from different
# models. Stored as a small JSON sidecar; the LanceDB schema is untouched.

def _row_count() -> int:
    tbl = get_table()
    if tbl is None:
        return 0
    try:
        return tbl.count_rows()
    except Exception:
        return len(_column_values(tbl, "chunk_id"))


def read_index_metadata() -> Optional[dict]:
    """Return the persisted index metadata, or None if absent/unreadable."""
    path = config.INDEX_META_PATH
    if not path.exists():
        return None
    try:
        with path.open("r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception as exc:  # noqa: BLE001
        log.warning("Could not read index metadata (%s): %s", path, exc)
        return None


def write_index_metadata(model: str, dimensions: int) -> dict:
    """Record which embedding provider/model/dimensions built the index."""
    config.ensure_dirs()
    meta = {
        "embedding_provider": config.EMBEDDING_PROVIDER,
        "embedding_model": model,
        "embedding_dimensions": int(dimensions),
        "created_at": datetime.now(tz=timezone.utc).isoformat(),
    }
    with config.INDEX_META_PATH.open("w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
    return meta


def delete_index_metadata() -> None:
    try:
        config.INDEX_META_PATH.unlink()
    except FileNotFoundError:
        pass


def check_index_compatibility(model: str, dimensions: int) -> None:
    """Raise IndexMismatchError if the index was built with a different model."""
    if _row_count() == 0:
        return  # empty index — any model may claim it
    meta = read_index_metadata()
    reset_hint = (
        "Reset and re-index:\n"
        "  python helper/main.py reset\n"
        "  python helper/main.py index \"/path/to/folder\" --force"
    )
    if meta is None:
        raise IndexMismatchError(
            "The existing index has no embedding metadata (it predates this version "
            f"or was built with a different model). {reset_hint}"
        )
    if (meta.get("embedding_model") != model
            or int(meta.get("embedding_dimensions", -1)) != int(dimensions)):
        raise IndexMismatchError(
            f"Index was built with '{meta.get('embedding_model')}' "
            f"({meta.get('embedding_dimensions')} dims) but the configured model is "
            f"'{model}' ({dimensions} dims). Embeddings from different models must not "
            f"be mixed. {reset_hint}"
        )


def ensure_index_metadata(model: str, dimensions: int) -> None:
    """Write metadata for a fresh/empty index; keep it once rows exist."""
    if read_index_metadata() is None or _row_count() == 0:
        write_index_metadata(model, dimensions)


def get_status() -> dict:
    tbl = get_table()
    if tbl is None:
        return {"total_chunks": 0, "total_files": 0, "db_path": str(config.DB_PATH)}
    try:
        total_chunks = tbl.count_rows()
    except Exception:
        total_chunks = len(_column_values(tbl, "chunk_id"))
    total_files = len(set(_column_values(tbl, "file_path")))
    return {
        "total_chunks": total_chunks,
        "total_files": total_files,
        "db_path": str(config.DB_PATH),
    }
