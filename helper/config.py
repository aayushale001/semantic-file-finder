"""Central configuration for the Semantic File Finder helper.

Reads settings from environment variables (optionally via a .env file) and
exposes paths, model settings, chunking parameters and the supported file
types. Also wires up logging so that *nothing* is written to stdout — stdout is
reserved exclusively for the JSON the Swift app parses.
"""
from __future__ import annotations

import logging
import os
from pathlib import Path

from dotenv import load_dotenv

# Load a .env from the repo root (one level up from helper/) and from the CWD.
_HELPER_DIR = Path(__file__).resolve().parent
_REPO_ROOT = _HELPER_DIR.parent
load_dotenv(_REPO_ROOT / ".env")
load_dotenv()  # also honor a .env in the current working directory


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}

# --- Paths -------------------------------------------------------------------
APP_DATA_DIR = Path(os.path.expanduser(os.getenv("APP_DATA_DIR", "~/.semantic_file_finder")))
DB_PATH = APP_DATA_DIR / "index.lance"
LOG_DIR = APP_DATA_DIR / "logs"
SETTINGS_PATH = APP_DATA_DIR / "settings.json"
INDEX_META_PATH = APP_DATA_DIR / "index_meta.json"
TABLE_NAME = "chunks"

# --- Gemini embeddings -------------------------------------------------------
EMBEDDING_PROVIDER = "gemini"
# The default is the multimodal-ready model. This app is intended to grow into
# images/audio/video, so gemini-embedding-2 is the intended default. The older
# gemini-embedding-001 is allowed ONLY as an explicit text-only fallback, and
# gemini-embedding-v1 is rejected outright (see resolve_embedding_model()).
DEFAULT_EMBEDDING_MODEL = "gemini-embedding-2"

GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "").strip()
EMBEDDING_MODEL = os.getenv("GEMINI_EMBEDDING_MODEL", DEFAULT_EMBEDDING_MODEL).strip()
# Output dimensionality. Must match between indexing and search (and is recorded
# in the index metadata so the two can never silently diverge).
EMBEDDING_DIMENSIONS = int(os.getenv("GEMINI_EMBEDDING_DIMENSIONS", "768"))
EMBEDDING_BATCH_SIZE = int(os.getenv("GEMINI_EMBEDDING_BATCH_SIZE", "32"))
# When true, the text-only fallback model (gemini-embedding-001) is permitted.
TEXT_ONLY_MODE = _env_bool("TEXT_ONLY_MODE", False)


class EmbeddingModelError(RuntimeError):
    """Raised when the configured embedding model is not allowed."""


def resolve_embedding_model() -> str:
    """Validate GEMINI_EMBEDDING_MODEL and return the model to use.

    Rules:
      * gemini-embedding-v1   -> hard error (never allowed)
      * gemini-embedding-001  -> allowed only when TEXT_ONLY_MODE=true (fallback)
      * anything else         -> used as configured (default: gemini-embedding-2)
    """
    model = (EMBEDDING_MODEL or "").strip()
    if not model:
        return DEFAULT_EMBEDDING_MODEL
    normalized = model.lower()

    if normalized == "gemini-embedding-v1":
        raise EmbeddingModelError(
            "Embedding model 'gemini-embedding-v1' is not supported. Use "
            "'gemini-embedding-2' (the multimodal default), or set "
            "GEMINI_EMBEDDING_MODEL=gemini-embedding-001 together with "
            "TEXT_ONLY_MODE=true for an explicit text-only fallback."
        )
    if normalized == "gemini-embedding-001":
        if not TEXT_ONLY_MODE:
            raise EmbeddingModelError(
                "Embedding model 'gemini-embedding-001' is a text-only fallback and "
                "must be enabled explicitly. Set TEXT_ONLY_MODE=true to use it, or "
                "switch to the multimodal default 'gemini-embedding-2'."
            )
        return "gemini-embedding-001"

    return model

# --- Chunking ----------------------------------------------------------------
CHUNK_SIZE = int(os.getenv("CHUNK_SIZE", "1200"))      # target chars per chunk (1000-1500)
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "200"))  # overlap in chars (150-250)
PREVIEW_MAX = 300                                       # max chars in content_preview
CODE_CHUNK_LINES = int(os.getenv("CODE_CHUNK_LINES", "120"))  # lines per code chunk (80-150)

# --- Scanning ----------------------------------------------------------------
# extension -> modality
SUPPORTED_EXTENSIONS = {
    ".txt": "text",
    ".md": "text",
    ".pdf": "pdf",
    ".docx": "docx",
    ".py": "code",
    ".js": "code",
    ".ts": "code",
    ".tsx": "code",
    ".jsx": "code",
    ".cpp": "code",
    ".c": "code",
    ".h": "code",
    ".hpp": "code",
    ".java": "code",
    ".html": "code",
    ".css": "code",
    ".json": "code",
}

# Directories that are never scanned (in addition to anything starting with ".").
IGNORED_DIRS = {
    ".git", "node_modules", ".venv", "venv", "__pycache__",
    ".DS_Store", "dist", "build", ".idea", ".vscode",
    ".mypy_cache", ".pytest_cache", ".tox", ".next", "target",
}


def ensure_dirs() -> None:
    """Create the app data + logs directories if they do not exist."""
    APP_DATA_DIR.mkdir(parents=True, exist_ok=True)
    LOG_DIR.mkdir(parents=True, exist_ok=True)


_LOGGING_CONFIGURED = False


def setup_logging() -> None:
    """Send logs to stderr and a log file — never stdout."""
    global _LOGGING_CONFIGURED
    if _LOGGING_CONFIGURED:
        return
    ensure_dirs()

    handlers: list[logging.Handler] = []
    try:
        from rich.console import Console
        from rich.logging import RichHandler
        handlers.append(RichHandler(console=Console(stderr=True), show_path=False, rich_tracebacks=True))
    except Exception:  # pragma: no cover - rich should be installed, but be safe
        import sys
        handlers.append(logging.StreamHandler(sys.stderr))
    try:
        handlers.append(logging.FileHandler(LOG_DIR / "helper.log"))
    except Exception:
        pass

    logging.basicConfig(
        level=os.getenv("LOG_LEVEL", "INFO"),
        format="%(message)s",
        datefmt="[%X]",
        handlers=handlers,
    )
    _LOGGING_CONFIGURED = True
