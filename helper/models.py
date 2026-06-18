"""Pydantic data models shared across the helper."""
from __future__ import annotations

from typing import List, Optional

from pydantic import BaseModel


class TextUnit(BaseModel):
    """A unit of extracted text: a whole document, or a single PDF page."""

    text: str
    page_number: Optional[int] = None


class ScannedFile(BaseModel):
    """A supported file discovered on disk, with change-detection metadata."""

    file_id: str
    file_path: str
    file_name: str
    file_extension: str
    modality: str
    file_size_bytes: int
    file_modified_at: str
    file_hash: str


class ChunkRecord(BaseModel):
    """One row in the LanceDB `chunks` table."""

    chunk_id: str
    file_id: str
    file_path: str
    file_name: str
    file_extension: str
    modality: str
    content_preview: str
    full_text: str
    page_number: Optional[int] = None
    chunk_index: int
    start_char: Optional[int] = None
    end_char: Optional[int] = None
    file_size_bytes: int
    file_modified_at: str
    file_hash: str
    embedding: List[float]
    indexed_at: str


class SearchResult(BaseModel):
    """A single search hit returned to the app."""

    file_name: str
    file_path: str
    file_extension: str
    content_preview: str
    page_number: Optional[int] = None
    chunk_index: int
    score: Optional[float] = None
