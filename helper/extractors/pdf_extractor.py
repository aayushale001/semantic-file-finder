"""PDF extractor using pypdf. One TextUnit per page."""
from __future__ import annotations

import logging
from typing import List

import config
from models import TextUnit

log = logging.getLogger(__name__)


def extract(file_path: str) -> List[TextUnit]:
    from pypdf import PdfReader  # imported lazily so other commands don't need it

    units: List[TextUnit] = []
    reader = PdfReader(file_path)
    page_count = len(reader.pages)
    if page_count > config.MAX_PDF_PAGES:
        raise ValueError(
            f"PDF page budget exceeded: {page_count} pages, "
            f"limit is {config.MAX_PDF_PAGES}"
        )
    for i, page in enumerate(reader.pages):
        text = page.extract_text() or ""
        if not text.strip():
            # Warn (likely a scanned/image page) but never crash.
            log.warning("PDF page %d in %s has little or no extractable text",
                        i + 1, file_path)
        units.append(TextUnit(text=text, page_number=i + 1))
    return units
