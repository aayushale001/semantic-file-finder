# Helper CLI

Python helper for Fosvera. It scans a folder, extracts and chunks
text, embeds chunks with Gemini Embedding 2, stores them in LanceDB, and answers
natural-language searches. It also provides a local filename/path/text search
fallback that does not call Gemini.

## Contract with the app

- **stdout is a single JSON object.** Nothing else is written to stdout.
  (Exception: `index --progress` streams newline-delimited JSON — see below.)
- Logs go to **stderr** and to `~/.semantic_file_finder/logs/helper.log` (the
  stable legacy directory retained for existing tester indexes).
- Success: `{"status": "success", ...}` · Failure: `{"status": "error", "message": "..."}`.

## Commands

```bash
python main.py index "/path/to/folder" [--force] [--progress] [--prune] [--json]
python main.py search "natural language query" [--limit 10] [--scope auto|all|documents|images|audio|video]
python main.py local-search "filename or text" [--limit 10] [--scope auto|all|documents|images|audio|video]
python main.py list
python main.py status
python main.py remove "/path/to/folder"
python main.py reset
python main.py model-info
python main.py check-key
python main.py serve
```

| Command | Returns |
|---|---|
| `index` | `{indexed_files, skipped_files, indexed_chunks, pruned_files, errors[]}` |
| `search` | `{query, scope, results[]}` (sorted by similarity; `--scope` limits to a kind) |
| `local-search` | `{query, scope, results[]}` (offline filename/path/text matches; no Gemini call) |
| `list` | `{files[]}` — distinct indexed files (`file_path, file_name, file_extension, modality, chunk_count, …`) |
| `status` | `{total_chunks, total_files, db_path}` |
| `remove` | `{removed_files}` (drops every indexed file under the folder) |
| `reset` | `{message}` (drops the table + index metadata) |
| `model-info` | `{embedding_provider, embedding_model, embedding_dimensions, text_only_mode, has_api_key}` |
| `check-key` | validates the configured Gemini key with a lightweight `models.list` metadata call (`error_code`: `no_api_key` / `invalid_api_key`) |
| `serve` | persistent JSON-lines server (see below) |

`index` skips files whose path + mtime + size are unchanged unless `--force` is
given. One failing file never aborts the whole job — it is added to `errors`.

With `--progress`, `index` instead streams **newline-delimited JSON** so the app
can show a live progress bar: a `{"event": "start", "total": N}` line, one
`{"event": "progress", "current": i, "total": N, "file_name": …, "indexed_files":
…, "skipped_files": …}` line per file, then a final `{"event": "complete", …}`
line carrying the usual summary fields. With `--prune`, indexed files under the
folder that no longer exist on disk are removed afterward.

**`serve` — persistent server mode (the app's fast path).** Instead of paying a
fresh interpreter + LanceDB import (~1 s) per command, the app keeps one
`main.py serve` process alive and sends one JSON request per stdin line:

```
→ {"id": "1", "cmd": "search", "args": {"query": "tax invoices", "scope": "auto", "limit": 10}}
← {"id": "1", "type": "result", "status": "success", "results": [...]}
```

Each response line carries the request's `id` and a `type` — `result`, `error`
(same `message`/`error_code` fields as the CLI), or `progress` (for `index` when
`"progress": true` is passed). The server prints `{"type": "ready"}` on startup,
answers requests serially, reuses the CLI's exact payload shapes, and exits
cleanly on stdin EOF. Commands: `ping`, `search`, `local-search`, `index`,
`list`, `status`, `model-info`, `check-key`, `remove`, `reset`.

**Media (`gemini-embedding-2`).** Text/docs/code are extracted and chunked; images,
audio, and video are embedded directly — no text extraction — into the *same*
vector space, so a text query can match them. To stay bounded on big files,
**video is sampled into evenly-spaced still frames** (one ~every
`VIDEO_FRAME_INTERVAL_SECONDS`, capped at `MAX_VIDEO_FRAMES`) and **long audio into
clips** under the 180s cap (capped at `MAX_AUDIO_SEGMENTS`) — so a feature-length
film becomes a few dozen small image embeddings, not dozens of huge uploads. Every
ffmpeg call and API request has a timeout, indexing reports live per-segment
progress, segments over `MEDIA_INLINE_MAX_BYTES` use the Files API, and segments
over `MAX_MEDIA_SEGMENT_BYTES` are skipped before upload. Media needs the
multimodal model; with the `gemini-embedding-001` text-only fallback, media files
are skipped (recorded in `errors[]`).

**Modality gap & `--scope`.** Text and media occupy different regions of the
shared space, so for a text query the text documents score higher than images of
the same subject and crowd them out of a mixed ranking. `--scope images` (or
`audio` / `video` / `documents`) prefilters to one kind so the best matches of
that kind surface. The default `--scope auto` first checks the query for keyword
cues (photo, pdf, clip, podcast, …) and resolves the kind with **no API call**;
only when there's no clear cue does it ask a small generative model
(`GEMINI_GENERATION_MODEL`) to read the intent. When the kind is still unclear (or
`--scope all`), results are a **reciprocal-rank-fusion blend** across kinds, so
images/audio/video are fairly represented. The response includes `detected_scope`
and `resolved_scope` so callers can show what was searched.

## Modules

| File | Responsibility |
|---|---|
| `config.py` | env/.env settings, paths, logging, embedding-model validation |
| `scanner.py` | recursive scan, ignore hidden/system dirs, deterministic IDs/hashes |
| `extractors/` | `text`, `code`, `pdf` (pypdf, per page), `docx` (python-docx) |
| `chunker.py` | char-window chunks (text/pdf/docx) and line-range chunks (code) |
| `media.py` | split image/audio/video into embeddable segments (ffmpeg via imageio-ffmpeg) |
| `embeddings.py` | Gemini embedding (text + media) with batching, retries, L2 normalization |
| `vector_store.py` | LanceDB table, add/search/reset/status, index metadata |
| `search.py` | embed query → (auto-scope / blend) → search LanceDB → JSON results |
| `intent.py` | classify a query's intended kind for `--scope auto` (keyword cues first, generative model only when unclear) |
| `models.py` | Pydantic models (`ChunkRecord`, `SearchResult`, …) |

## Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | — | required for `index`/`search` |
| `APP_DATA_DIR` | `~/.semantic_file_finder` | data/index/logs location |
| `GEMINI_EMBEDDING_MODEL` | `gemini-embedding-2` | embedding model |
| `GEMINI_GENERATION_MODEL` | `gemini-2.5-flash` | model for `--scope auto` fallback when keyword cues don't resolve the kind |
| `GEMINI_EMBEDDING_DIMENSIONS` | `768` | output dimensionality |
| `TEXT_ONLY_MODE` | `false` | allow the `gemini-embedding-001` fallback |
| `CHUNK_SIZE` / `CHUNK_OVERLAP` | `1200` / `200` | text chunking |
| `CODE_CHUNK_LINES` | `120` | lines per code chunk |
| `MAX_TEXT_FILE_BYTES` / `MAX_CODE_FILE_BYTES` | `5242880` / `5242880` | max text/code file size indexed |
| `MAX_PDF_FILE_BYTES` / `MAX_DOCX_FILE_BYTES` | `52428800` / `52428800` | max PDF/DOCX file size indexed |
| `MAX_EXTRACTED_CHARS_PER_FILE` | `500000` | max extracted text per file before skipping |
| `MAX_CHUNKS_PER_FILE` | `500` | max text chunks or media segments per file |
| `MAX_PDF_PAGES` | `250` | max PDF pages extracted per file |
| `MAX_MEDIA_FILE_BYTES` | `262144000` | max image/audio/video file size indexed |
| `MAX_MEDIA_SEGMENT_BYTES` | `52428800` | max media segment size uploaded to Gemini |
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

`status`, `reset`, `model-info`, `list`, and `local-search` also work without a
key. `index` and semantic `search` require `GEMINI_API_KEY` and internet access.

Source/CLI development loads `.env` by default. Frozen PyInstaller helpers do
not load `.env` by default; set `SFF_LOAD_DOTENV=1` only for explicit developer
testing.
