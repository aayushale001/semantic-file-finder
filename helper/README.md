# Helper CLI

Python helper for the Semantic File Finder. It scans a folder, extracts and chunks
text, embeds chunks with Gemini Embedding 2, stores them in LanceDB, and answers
natural-language searches.

## Contract with the app

- **stdout is a single JSON object.** Nothing else is written to stdout.
  (Exception: `index --progress` streams newline-delimited JSON — see below.)
- Logs go to **stderr** and to `~/.semantic_file_finder/logs/helper.log`.
- Success: `{"status": "success", ...}` · Failure: `{"status": "error", "message": "..."}`.

## Commands

```bash
python main.py index "/path/to/folder" [--force] [--progress] [--json]
python main.py search "natural language query" [--limit 10] [--scope all|documents|images|audio|video]
python main.py list
python main.py status
python main.py reset
python main.py model-info
```

| Command | Returns |
|---|---|
| `index` | `{indexed_files, skipped_files, indexed_chunks, errors[]}` |
| `search` | `{query, scope, results[]}` (sorted by similarity; `--scope` limits to a kind) |
| `list` | `{files[]}` — distinct indexed files (`file_path, file_name, file_extension, modality, chunk_count, …`) |
| `status` | `{total_chunks, total_files, db_path}` |
| `reset` | `{message}` (drops the table + index metadata) |
| `model-info` | `{embedding_provider, embedding_model, embedding_dimensions, text_only_mode}` |

`index` skips files whose path + mtime + size are unchanged unless `--force` is
given. One failing file never aborts the whole job — it is added to `errors`.

With `--progress`, `index` instead streams **newline-delimited JSON** so the app
can show a live progress bar: a `{"event": "start", "total": N}` line, one
`{"event": "progress", "current": i, "total": N, "file_name": …, "indexed_files":
…, "skipped_files": …}` line per file, then a final `{"event": "complete", …}`
line carrying the usual summary fields.

**Media (`gemini-embedding-2`).** Text/docs/code are extracted and chunked; images,
audio, and video are embedded directly — no text extraction — into the *same*
vector space, so a text query can match them. To stay bounded on big files,
**video is sampled into evenly-spaced still frames** (one ~every
`VIDEO_FRAME_INTERVAL_SECONDS`, capped at `MAX_VIDEO_FRAMES`) and **long audio into
clips** under the 180s cap (capped at `MAX_AUDIO_SEGMENTS`) — so a feature-length
film becomes a few dozen small image embeddings, not dozens of huge uploads. Every
ffmpeg call and API request has a timeout, indexing reports live per-segment
progress, and segments over `MEDIA_INLINE_MAX_BYTES` use the Files API. Media needs
the multimodal model; with the `gemini-embedding-001` text-only fallback, media
files are skipped (recorded in `errors[]`).

**Modality gap & `--scope`.** Text and media occupy different regions of the
shared space, so for a text query the text documents score higher than images of
the same subject and crowd them out of a mixed ranking. `--scope images` (or
`audio` / `video` / `documents`) prefilters to one kind so the best matches of
that kind surface; `--scope all` (default) ranks everything together by raw
similarity.

## Modules

| File | Responsibility |
|---|---|
| `config.py` | env/.env settings, paths, logging, embedding-model validation |
| `scanner.py` | recursive scan, ignore hidden/system dirs, deterministic IDs/hashes |
| `extractors/` | `text`, `code`, `pdf` (PyMuPDF, per page), `docx` (python-docx) |
| `chunker.py` | char-window chunks (text/pdf/docx) and line-range chunks (code) |
| `media.py` | split image/audio/video into embeddable segments (ffmpeg via imageio-ffmpeg) |
| `embeddings.py` | Gemini embedding (text + media) with batching, retries, L2 normalization |
| `vector_store.py` | LanceDB table, add/search/reset/status, index metadata |
| `search.py` | embed query → search LanceDB → JSON results |
| `models.py` | Pydantic models (`ChunkRecord`, `SearchResult`, …) |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | — | required for `index`/`search` |
| `APP_DATA_DIR` | `~/.semantic_file_finder` | data/index/logs location |
| `GEMINI_EMBEDDING_MODEL` | `gemini-embedding-2` | embedding model |
| `GEMINI_EMBEDDING_DIMENSIONS` | `768` | output dimensionality |
| `TEXT_ONLY_MODE` | `false` | allow the `gemini-embedding-001` fallback |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `1200` / `200` | text chunking |
| `CODE_CHUNK_LINES` | `120` | lines per code chunk |
| `MAX_VIDEO_FRAMES` | `30` | max still frames sampled per video |
| `VIDEO_FRAME_INTERVAL_SECONDS` | `10` | target spacing between sampled frames |
| `AUDIO_SEGMENT_SECONDS` / `MAX_AUDIO_SEGMENTS` | `170` / `30` | audio clip length / max clips per file |
| `MEDIA_INLINE_MAX_BYTES` | `15728640` | media segments larger than this use the Files API |
| `FFMPEG_TIMEOUT_SECONDS` / `GEMINI_REQUEST_TIMEOUT_MS` | `120` / `120000` | hard timeouts so a bad file can't hang indexing |
| `LOG_LEVEL` | `INFO` | logging verbosity (stderr/file) |

## Testing from the terminal

Scanning, extraction, and chunking need no API key:

```bash
python -c "import sys; sys.path.insert(0,'.'); import scanner; \
print(len(scanner.scan_folder('../test_files')), 'files')"
```

`status`, `reset`, and `model-info` also work without a key. `index` and `search`
require `GEMINI_API_KEY`.
