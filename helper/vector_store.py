"""LanceDB-backed vector store for chunk rows + metadata."""
from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import List, Optional

import pyarrow as pa

import config
from models import ChunkRecord, SearchResult

log = logging.getLogger(__name__)


class IndexMismatchError(RuntimeError):
    """Raised when the index's embedding model differs from the configured one."""


_db = None


def get_db():
    """Connect to (creating if needed) the local LanceDB at config.DB_PATH.

    The connection is cached for the life of the process — in `serve` mode this
    keeps repeat commands fast. Tables are deliberately *not* cached:
    `open_table` re-reads the latest committed version, so writes from a
    separate `index` subprocess stay visible to the server's reads.
    """
    global _db
    if _db is None:
        import lancedb
        config.ensure_dirs()
        _db = lancedb.connect(str(config.DB_PATH))
    return _db


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


def _rows(tbl, columns: List[str]) -> List[dict]:
    """Read several columns as aligned row dicts (single projected scan)."""
    try:
        return tbl.to_lance().to_table(columns=columns).to_pylist()
    except Exception:
        try:
            return tbl.to_arrow().select(columns).to_pylist()
        except Exception:
            return []


def get_indexed_file_ids() -> set:
    """Set of file_ids already present — used to skip unchanged files."""
    tbl = get_table()
    if tbl is None:
        return set()
    return set(_column_values(tbl, "file_id"))


def list_indexed_files() -> List[dict]:
    """One entry per distinct indexed file (with chunk count), for the gallery."""
    tbl = get_table()
    if tbl is None:
        return []
    cols = ["file_path", "file_name", "file_extension", "modality",
            "file_size_bytes", "file_modified_at", "indexed_at"]
    by_path: dict = {}
    for r in _rows(tbl, cols):
        path = r.get("file_path")
        if path is None:
            continue
        entry = by_path.get(path)
        if entry is None:
            by_path[path] = {
                "file_path": path,
                "file_name": r.get("file_name"),
                "file_extension": r.get("file_extension"),
                "modality": r.get("modality"),
                "file_size_bytes": r.get("file_size_bytes"),
                "file_modified_at": r.get("file_modified_at"),
                "indexed_at": r.get("indexed_at"),
                "chunk_count": 1,
            }
        else:
            entry["chunk_count"] += 1
            if (r.get("indexed_at") or "") > (entry["indexed_at"] or ""):
                entry["indexed_at"] = r.get("indexed_at")
    files = list(by_path.values())
    files.sort(key=lambda e: (e["file_name"] or "").lower())
    return files


def search_chunks(
    query_embedding: List[float],
    limit: int = 10,
    modalities: Optional[set] = None,
) -> List[SearchResult]:
    tbl = get_table()
    if tbl is None:
        return []
    # NB: no .select() projection — LanceDB is deprecating auto-inclusion of the
    # `_distance` score when columns are projected, and we rely on that score.
    query = tbl.search(query_embedding).metric("cosine")
    if modalities:
        # Prefilter so the limit applies *after* restricting to the chosen kinds
        # (text and media occupy different regions of the space — the "modality
        # gap" — so without this, media is crowded out of mixed results).
        quoted = ", ".join("'" + m.replace("'", "''") + "'" for m in sorted(modalities))
        query = query.where(f"modality IN ({quoted})", prefilter=True)
    rows = query.limit(limit).to_list()
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


def _term_positions(text: str, terms: List[str]) -> int:
    haystack = (text or "").lower()
    return sum(1 for term in terms if term in haystack)


def local_search(
    query: str,
    limit: int = 10,
    modalities: Optional[set] = None,
) -> List[SearchResult]:
    """Search the local index without Gemini.

    This is the offline / fallback path: it ranks indexed files by filename,
    path, and stored extracted text/preview. It returns at most one best chunk per
    file so the UI behaves like a normal file-manager search instead of a chunk
    search.
    """
    tbl = get_table()
    if tbl is None:
        return []

    terms = [t for t in re.findall(r"[a-z0-9]+", (query or "").lower()) if t]
    if not terms:
        return []

    cols = [
        "file_path", "file_name", "file_extension", "modality",
        "content_preview", "full_text", "page_number", "chunk_index",
    ]
    best_by_file: dict = {}
    for r in _rows(tbl, cols):
        if modalities and r.get("modality") not in modalities:
            continue

        file_name = r.get("file_name") or ""
        file_path = r.get("file_path") or ""
        preview = r.get("content_preview") or ""
        full_text = r.get("full_text") or ""

        name_hits = _term_positions(file_name, terms)
        path_hits = _term_positions(file_path, terms)
        preview_hits = _term_positions(preview, terms)
        text_hits = _term_positions(full_text, terms)
        if not (name_hits or path_hits or preview_hits or text_hits):
            continue

        # Prefer filename/path hits like Finder would, then fall back to indexed
        # content. Add an all-terms bonus so precise queries rise naturally.
        searchable = " ".join([file_name, file_path, preview, full_text]).lower()
        all_terms_bonus = 20 if all(term in searchable for term in terms) else 0
        score = (
            name_hits * 100
            + path_hits * 30
            + preview_hits * 12
            + text_hits * 4
            + all_terms_bonus
        )

        path = file_path
        existing = best_by_file.get(path)
        if existing is not None and score <= existing[0]:
            continue
        best_by_file[path] = (score, r)

    ranked = sorted(
        best_by_file.values(),
        key=lambda item: (-item[0], (item[1].get("file_name") or "").lower()),
    )
    results: List[SearchResult] = []
    for score, r in ranked[:max(1, limit)]:
        results.append(SearchResult(
            file_name=r["file_name"],
            file_path=r["file_path"],
            file_extension=r["file_extension"],
            content_preview=r.get("content_preview") or f"Local match — {r['file_name']}",
            page_number=r.get("page_number"),
            chunk_index=r.get("chunk_index") or 0,
            score=None,
        ))
    return results


# --- watched-folder maintenance (multi-root + file watching) ----------------
# Stored file_paths are absolute and symlink-resolved (scanner uses Path.resolve),
# so roots are normalized the same way before prefix matching.

def _norm_root(root: str) -> str:
    return os.path.realpath(os.path.expanduser(root))


def _is_under(path: str, root: str) -> bool:
    return path == root or path.startswith(root + os.sep)


def indexed_files_under(root: str) -> List[str]:
    """Distinct indexed file paths that live under `root`."""
    tbl = get_table()
    if tbl is None:
        return []
    root = _norm_root(root)
    paths = set(_column_values(tbl, "file_path"))
    return sorted(p for p in paths if p and _is_under(p, root))


def prune_missing(root: str) -> List[str]:
    """Delete indexed files under `root` that no longer exist on disk.

    Powers the file-watcher's incremental sync: when files are deleted or moved,
    their stale chunks are removed so search never points at vanished files.
    """
    removed: List[str] = []
    for path in indexed_files_under(root):
        if not os.path.exists(path):
            delete_file(path)
            removed.append(path)
    return removed


def remove_under(root: str) -> int:
    """Delete every indexed file under `root` (when a watched folder is removed)."""
    paths = indexed_files_under(root)
    for path in paths:
        delete_file(path)
    return len(paths)


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
