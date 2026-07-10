"""Recursively scan a folder for supported files and compute stable IDs."""
from __future__ import annotations

import hashlib
import logging
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import List

import config
from models import ScannedFile

log = logging.getLogger(__name__)


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat()


def _hash_file(path: Path, block_size: int = 1 << 20) -> str:
    """SHA256 of the file's bytes (streamed so large files don't blow memory)."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(block_size), b""):
            h.update(block)
    return h.hexdigest()


def compute_file_id(file_path: str, modified_time: str, file_size: int) -> str:
    """Deterministic file id: sha256(path + modified_time + size)."""
    raw = f"{file_path}|{modified_time}|{file_size}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def compute_chunk_id(file_id: str, chunk_index: int, content: str) -> str:
    """Deterministic chunk id: sha256(file_id + chunk_index + content)."""
    raw = f"{file_id}|{chunk_index}|{content}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _is_relative_to(path: Path, root: Path) -> bool:
    """True when `path` is inside `root` after both are resolved."""
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def scan_folder(folder: str) -> List[ScannedFile]:
    """Walk `folder` and return the supported files (hidden/system dirs skipped)."""
    root = Path(folder).expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"Folder does not exist: {root}")
    if not root.is_dir():
        raise NotADirectoryError(f"Not a folder: {root}")

    found: List[ScannedFile] = []
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune hidden, ignored, and symlinked directories in place so os.walk
        # never enters a path that can escape the user-selected root.
        dirnames[:] = [
            d for d in dirnames
            if (
                not d.startswith(".")
                and d not in config.IGNORED_DIRS
                and not (Path(dirpath) / d).is_symlink()
            )
        ]
        for name in filenames:
            if name.startswith("."):  # skip hidden files (.DS_Store, dotfiles)
                continue
            ext = Path(name).suffix.lower()
            modality = config.SUPPORTED_EXTENSIONS.get(ext)
            if modality is None:
                continue

            full = Path(dirpath) / name
            try:
                if full.is_symlink():
                    log.warning("Skipping symlinked file outside scan policy: %s", full)
                    continue
                resolved = full.resolve(strict=True)
                if not _is_relative_to(resolved, root):
                    log.warning("Skipping file outside scan root: %s -> %s", full, resolved)
                    continue
                st = resolved.stat()
            except OSError as exc:
                log.warning("Could not stat %s: %s", full, exc)
                continue

            modified_at = _iso(st.st_mtime)
            file_path = str(resolved)
            file_id = compute_file_id(file_path, modified_at, st.st_size)
            # file_hash is metadata only (change detection uses file_id), so we
            # skip re-reading multi-GB media on every scan.
            if st.st_size <= config.MEDIA_HASH_MAX_BYTES:
                try:
                    file_hash = _hash_file(resolved)
                except OSError as exc:
                    log.warning("Could not hash %s: %s", resolved, exc)
                    file_hash = file_id
            else:
                file_hash = file_id

            found.append(ScannedFile(
                file_id=file_id,
                file_path=file_path,
                file_name=name,
                file_extension=ext,
                modality=modality,
                file_size_bytes=st.st_size,
                file_modified_at=modified_at,
                file_hash=file_hash,
            ))

    found.sort(key=lambda f: f.file_path)
    return found
