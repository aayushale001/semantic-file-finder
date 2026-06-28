"""Code extractor.

Read source files as text. No AST parsing yet — the chunker splits code by line
ranges (see chunker._chunk_code).
"""
from __future__ import annotations

from pathlib import Path
from typing import List

from models import TextUnit


def extract(file_path: str) -> List[TextUnit]:
    path = Path(file_path)
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        text = path.read_text(encoding="utf-8", errors="ignore")
    return [TextUnit(text=text, page_number=None)]
