"""PDF extractor using PyMuPDF (fitz). One TextUnit per page."""
from __future__ import annotations

import logging
from typing import List

from models import TextUnit

log = logging.getLogger(__name__)


def extract(file_path: str) -> List[TextUnit]:
    import fitz  # PyMuPDF; imported lazily so other commands don't need it

    units: List[TextUnit] = []
    doc = fitz.open(file_path)
    try:
        for i, page in enumerate(doc):
            text = page.get_text("text") or ""
            if not text.strip():
                # Warn (likely a scanned/image page) but never crash.
                log.warning("PDF page %d in %s has little or no extractable text",
                            i + 1, file_path)
            units.append(TextUnit(text=text, page_number=i + 1))
    finally:
        doc.close()
    return units
