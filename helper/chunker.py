"""Split extracted text into overlapping chunks.

Strategy:
  * text / pdf / docx -> character windows (~CHUNK_SIZE) with overlap, trying
    not to split in the middle of a word. PDF pages are chunked individually so
    each chunk keeps its page number; long pages split into several chunks.
  * code -> line-range chunks (~CODE_CHUNK_LINES lines each).
"""
from __future__ import annotations

from typing import List, Optional, Tuple

from pydantic import BaseModel

import config
from models import TextUnit


class Chunk(BaseModel):
    text: str
    page_number: Optional[int] = None
    chunk_index: int
    start_char: Optional[int] = None
    end_char: Optional[int] = None


def _split_text(text: str, size: int, overlap: int) -> List[Tuple[str, int, int]]:
    """Return (chunk_text, start_char, end_char) windows over `text`."""
    n = len(text)
    if n == 0:
        return []
    if overlap >= size:
        overlap = size // 4

    chunks: List[Tuple[str, int, int]] = []
    start = 0
    while start < n:
        end = min(start + size, n)
        if end < n:
            # Prefer to cut on whitespace in the back half of the window so we
            # don't split a word; fall back to a hard cut if none is found.
            window_min = start + size // 2
            cut = max(text.rfind(" ", window_min, end), text.rfind("\n", window_min, end))
            if cut > window_min:
                end = cut
        piece = text[start:end].strip()
        if piece:
            chunks.append((piece, start, end))
        if end >= n:
            break
        nxt = end - overlap
        start = nxt if nxt > start else end  # guarantee forward progress
    return chunks


def _chunk_code(units: List[TextUnit]) -> List[Chunk]:
    chunks: List[Chunk] = []
    idx = 0
    step = max(1, config.CODE_CHUNK_LINES)
    for unit in units:
        lines = unit.text.splitlines(keepends=True)
        offset = 0
        for i in range(0, len(lines), step):
            block = "".join(lines[i:i + step])
            length = len(block)
            if block.strip():
                chunks.append(Chunk(
                    text=block.strip("\n"),
                    page_number=None,
                    chunk_index=idx,
                    start_char=offset,
                    end_char=offset + length,
                ))
                idx += 1
            offset += length
    return chunks


def chunk_document(units: List[TextUnit], modality: str) -> List[Chunk]:
    """Turn extracted text units into ordered chunks for a single file."""
    if modality == "code":
        return _chunk_code(units)

    chunks: List[Chunk] = []
    idx = 0
    for unit in units:
        for piece, start, end in _split_text(unit.text, config.CHUNK_SIZE, config.CHUNK_OVERLAP):
            chunks.append(Chunk(
                text=piece,
                page_number=unit.page_number,
                chunk_index=idx,
                start_char=start,
                end_char=end,
            ))
            idx += 1
    return chunks
