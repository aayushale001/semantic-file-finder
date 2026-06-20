"""Semantic File Finder helper CLI.

Commands: index, search, status, reset. Each command prints one JSON object to
stdout (consumed by the Swift app); the lone exception is `index --progress`,
which streams newline-delimited JSON progress events. Logs go to stderr / a log
file.
"""
from __future__ import annotations

import concurrent.futures
import json
import logging
import sys
from datetime import datetime, timezone
from typing import Callable, List, Optional

import typer

import config
import embeddings
import media
import scanner
import vector_store
from chunker import chunk_document
from extractors import extract_file
from models import ChunkRecord, ScannedFile
from search import run_search

app = typer.Typer(add_completion=False, help="Semantic File Finder helper CLI")
log = logging.getLogger("helper")


def _emit(payload: dict) -> None:
    """Write a single JSON object to stdout — the only thing on stdout."""
    sys.stdout.write(json.dumps(payload))
    sys.stdout.write("\n")
    sys.stdout.flush()


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _preview(text: str) -> str:
    """A short, whitespace-collapsed preview (<= PREVIEW_MAX chars)."""
    return " ".join(text.split())[:config.PREVIEW_MAX]


def _media_model_supported() -> bool:
    """Media embedding needs the multimodal model, not the text-only fallback."""
    return config.resolve_embedding_model().lower() != "gemini-embedding-001"


_MEDIA_KIND = {"image": "Image", "audio": "Audio", "video": "Video"}


def _media_preview(modality: str, file_name: str, segment: "media.MediaSegment") -> str:
    """Human-readable label stored as the preview/full_text for a media segment."""
    kind = _MEDIA_KIND.get(modality, modality.title())
    if segment.label:
        return f"{kind} {segment.label} — {file_name}"
    return f"{kind} — {file_name}"


def _index_media_file(
    f: ScannedFile,
    on_segment: Optional[Callable[[int, int], None]] = None,
) -> List[ChunkRecord]:
    """Segment a media file and embed each segment into the shared vector space.

    `on_segment(done, total)` is called after each segment so a long file (e.g.
    a feature-length video sampled into many frames) shows live sub-progress.
    """
    indexed_at = _now_iso()
    with media.segmented(f.file_path, f.modality) as segments:
        seg_total = len(segments)
        if seg_total == 0:
            return []

        # Embed segments concurrently — a long audio/video file has many
        # independent clips/frames, and each embed is its own (slow-ish) API call.
        seg_by_index = {seg.index: seg for seg in segments}
        vectors: dict = {}
        workers = max(1, min(config.MEDIA_EMBED_CONCURRENCY, seg_total))
        done = 0
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            futures = {
                pool.submit(embeddings.embed_media_file, seg.path, seg.mime_type): seg.index
                for seg in segments
            }
            for future in concurrent.futures.as_completed(futures):
                # A segment failing after retries fails the whole file (so it's
                # retried next run rather than left partially indexed).
                vectors[futures[future]] = future.result()
                done += 1
                if on_segment is not None:
                    on_segment(done, seg_total)

        records: List[ChunkRecord] = []
        for index in sorted(vectors):
            seg = seg_by_index[index]
            preview = _media_preview(f.modality, f.file_name, seg)
            records.append(ChunkRecord(
                chunk_id=scanner.compute_chunk_id(f.file_id, seg.index, preview),
                file_id=f.file_id,
                file_path=f.file_path,
                file_name=f.file_name,
                file_extension=f.file_extension,
                modality=f.modality,
                content_preview=preview,
                full_text=preview,
                page_number=None,
                chunk_index=seg.index,
                start_char=None,
                end_char=None,
                file_size_bytes=f.file_size_bytes,
                file_modified_at=f.file_modified_at,
                file_hash=f.file_hash,
                embedding=vectors[index],
                indexed_at=indexed_at,
            ))
    return records


def run_index(
    folder: str,
    force: bool = False,
    progress: Optional[Callable[[dict], None]] = None,
) -> dict:
    """Index every supported file under `folder`. Returns a JSON-able summary.

    When `progress` is given it is called once per file with a small dict
    describing how far the job has gotten (current/total + running counters),
    which the caller can stream to the UI.
    """
    config.ensure_dirs()
    model = config.resolve_embedding_model()           # validate configured model
    vector_store.check_index_compatibility(model, config.EMBEDDING_DIMENSIONS)
    vector_store.ensure_index_metadata(model, config.EMBEDDING_DIMENSIONS)

    files: List[ScannedFile] = scanner.scan_folder(folder)
    existing_ids = set() if force else vector_store.get_indexed_file_ids()

    indexed_files = 0
    skipped_files = 0
    indexed_chunks = 0
    errors: List[str] = []
    total = len(files)

    if progress is not None:
        progress({"event": "start", "current": 0, "total": total})

    for i, f in enumerate(files, start=1):
        # The try/finally guarantees exactly one progress event per file, even
        # when we `continue` past a skipped or failed one.
        try:
            # Skip unchanged files (same path + mtime + size => same file_id).
            if not force and f.file_id in existing_ids:
                skipped_files += 1
                continue

            # Announce the file before (possibly slow) extraction/embedding so the
            # banner reflects the *active* file, not just the last completed one.
            if progress is not None:
                progress({
                    "event": "progress",
                    "current": i - 1,
                    "total": total,
                    "file_name": f.file_name,
                    "indexed_files": indexed_files,
                    "skipped_files": skipped_files,
                    "indexed_chunks": indexed_chunks,
                })

            if f.modality in config.MEDIA_MODALITIES:
                # ---- media: embed sampled segments (image / audio / video) ----
                if not _media_model_supported():
                    errors.append(
                        f"media:{f.file_name}: needs gemini-embedding-2 "
                        f"(text-only mode cannot embed media)"
                    )
                    continue

                def _on_segment(done: int, seg_total: int) -> None:
                    # Live sub-progress within a single (possibly long) media file.
                    if progress is not None:
                        progress({
                            "event": "progress",
                            "current": i - 1,          # files fully completed so far
                            "total": total,
                            "file_name": f.file_name,
                            "segment_current": done,
                            "segment_total": seg_total,
                            "indexed_files": indexed_files,
                            "skipped_files": skipped_files,
                            "indexed_chunks": indexed_chunks,
                        })

                try:
                    records = _index_media_file(f, on_segment=_on_segment)
                except Exception as exc:  # noqa: BLE001 - one bad file must not kill the job
                    log.exception("Media embedding failed for %s", f.file_path)
                    errors.append(f"media:{f.file_name}: {exc}")
                    continue
                if not records:
                    skipped_files += 1
                    errors.append(f"empty:{f.file_name}: no media segments")
                    continue
            else:
                # ---- text: extract -> chunk -> embed ----
                try:
                    units = extract_file(f.file_path, f.modality)
                except Exception as exc:  # noqa: BLE001 - one bad file must not kill the job
                    log.exception("Extraction failed for %s", f.file_path)
                    errors.append(f"extract:{f.file_name}: {exc}")
                    continue

                chunks = chunk_document(units, f.modality)
                if not chunks:
                    skipped_files += 1
                    errors.append(f"empty:{f.file_name}: no extractable text")
                    continue

                try:
                    vectors = embeddings.embed_batch(
                        [c.text for c in chunks], task_type=embeddings.TASK_DOCUMENT
                    )
                except Exception as exc:  # noqa: BLE001
                    log.exception("Embedding failed for %s", f.file_path)
                    errors.append(f"embed:{f.file_name}: {exc}")
                    continue

                indexed_at = _now_iso()
                records = []
                for chunk, vector in zip(chunks, vectors):
                    records.append(ChunkRecord(
                        chunk_id=scanner.compute_chunk_id(f.file_id, chunk.chunk_index, chunk.text),
                        file_id=f.file_id,
                        file_path=f.file_path,
                        file_name=f.file_name,
                        file_extension=f.file_extension,
                        modality=f.modality,
                        content_preview=_preview(chunk.text),
                        full_text=chunk.text,
                        page_number=chunk.page_number,
                        chunk_index=chunk.chunk_index,
                        start_char=chunk.start_char,
                        end_char=chunk.end_char,
                        file_size_bytes=f.file_size_bytes,
                        file_modified_at=f.file_modified_at,
                        file_hash=f.file_hash,
                        embedding=vector,
                        indexed_at=indexed_at,
                    ))

            # Replace any previous version of this file, then store fresh chunks.
            vector_store.delete_file(f.file_path)
            vector_store.add_chunks(records)
            indexed_files += 1
            indexed_chunks += len(records)
        finally:
            if progress is not None:
                progress({
                    "event": "progress",
                    "current": i,
                    "total": total,
                    "file_name": f.file_name,
                    "indexed_files": indexed_files,
                    "skipped_files": skipped_files,
                    "indexed_chunks": indexed_chunks,
                })

    return {
        "status": "success",
        "indexed_files": indexed_files,
        "skipped_files": skipped_files,
        "indexed_chunks": indexed_chunks,
        "errors": errors,
    }


@app.callback()
def _root() -> None:
    config.setup_logging()


@app.command()
def index(
    folder: str = typer.Argument(..., help="Folder to index"),
    force: bool = typer.Option(False, "--force", help="Re-index even unchanged files"),
    progress: bool = typer.Option(
        False, "--progress",
        help="Stream NDJSON progress events to stdout (one JSON object per line: "
             "start, progress per file, then a final complete summary)",
    ),
    json_output: bool = typer.Option(False, "--json", help="(Accepted; output is always JSON)"),
) -> None:
    """Recursively index supported files in a folder.

    Without --progress the command prints a single JSON summary object (the
    default contract). With --progress it prints newline-delimited JSON: a
    `start` event, one `progress` event per file, then a final `complete`
    event carrying the same summary fields.
    """
    try:
        if progress:
            summary = run_index(folder, force=force, progress=_emit)
            _emit({"event": "complete", **summary})
        else:
            _emit(run_index(folder, force=force))
    except Exception as exc:  # noqa: BLE001
        log.exception("index command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


@app.command()
def search(
    query: str = typer.Argument(..., help="Natural-language query"),
    limit: int = typer.Option(10, "--limit", help="Max results"),
    scope: str = typer.Option(
        "auto", "--scope",
        help="auto (LLM picks the kind) | all | documents | images | audio | video",
    ),
) -> None:
    """Search indexed files by meaning; 'auto' detects the kind from the query."""
    try:
        _emit(run_search(query, limit=limit, scope=scope))
    except Exception as exc:  # noqa: BLE001
        log.exception("search command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


@app.command()
def status() -> None:
    """Report how much is indexed and where the DB lives."""
    try:
        _emit({"status": "success", **vector_store.get_status()})
    except Exception as exc:  # noqa: BLE001
        log.exception("status command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


@app.command(name="list")
def list_files() -> None:
    """List the distinct files currently in the index (powers the app's gallery)."""
    try:
        _emit({"status": "success", "files": vector_store.list_indexed_files()})
    except Exception as exc:  # noqa: BLE001
        log.exception("list command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


@app.command()
def reset() -> None:
    """Delete and recreate the local index."""
    try:
        vector_store.reset_index()
        _emit({"status": "success", "message": "Index reset successfully"})
    except Exception as exc:  # noqa: BLE001
        log.exception("reset command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


@app.command(name="model-info")
def model_info() -> None:
    """Report the configured embedding provider/model/dimensions."""
    try:
        model = config.resolve_embedding_model()
        _emit({
            "status": "success",
            "embedding_provider": config.EMBEDDING_PROVIDER,
            "embedding_model": model,
            "embedding_dimensions": config.EMBEDDING_DIMENSIONS,
            "text_only_mode": config.TEXT_ONLY_MODE,
        })
    except Exception as exc:  # noqa: BLE001
        log.exception("model-info command failed")
        _emit({"status": "error", "message": str(exc)})
        raise typer.Exit(code=1)


if __name__ == "__main__":
    app()
