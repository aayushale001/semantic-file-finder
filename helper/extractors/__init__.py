"""Text extraction dispatch by modality."""
from __future__ import annotations

from typing import List

from models import TextUnit

from . import code_extractor, docx_extractor, pdf_extractor, text_extractor


def extract_file(file_path: str, modality: str) -> List[TextUnit]:
    """Extract text units from a file based on its modality."""
    if modality == "text":
        return text_extractor.extract(file_path)
    if modality == "code":
        return code_extractor.extract(file_path)
    if modality == "pdf":
        return pdf_extractor.extract(file_path)
    if modality == "docx":
        return docx_extractor.extract(file_path)
    raise ValueError(f"Unsupported modality: {modality}")
