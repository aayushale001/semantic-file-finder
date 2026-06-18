# Semantic File Finder

A native macOS app that indexes a folder of your files and lets you search them
by **meaning** instead of filename. A SwiftUI front end drives a small Python
helper that extracts text, embeds it with **Gemini Embedding 2**, and stores the
vectors in a local **LanceDB** database. Everything stays on your machine.

Supported files: `.txt` `.md` `.pdf` `.docx` and code (`.py` `.js` `.ts` `.tsx`
`.jsx` `.cpp` `.c` `.h` `.hpp` `.java` `.html` `.css` `.json`).

## Architecture

```
SwiftUI macOS App  ──runs──▶  Python helper CLI (JSON over stdout)
                                  │
            scan ▶ extract ▶ chunk ▶ Gemini Embedding 2 ▶ LanceDB
                                                              │
SwiftUI results  ◀──────────────  JSON  ◀─────────────────────┘
```

Gemini only creates embeddings. LanceDB stores and searches them. SwiftUI only
handles UI and calls the helper.

## Project structure

```
.
├── macos-app/
│   ├── Package.swift                # swift run (fastest dev path)
│   ├── project.yml                  # XcodeGen spec for a real .app
│   ├── SemanticFileFinder.entitlements
│   └── SemanticFileFinder/
│       ├── SemanticFileFinderApp.swift
│       ├── ContentView.swift
│       ├── Models/SearchResult.swift
│       ├── Services/HelperService.swift
│       └── Views/{FolderPickerView,IndexingView,SearchResultsView}.swift
├── helper/
│   ├── main.py                      # Typer CLI: index / search / status / reset / model-info
│   ├── config.py  scanner.py  chunker.py  embeddings.py
│   ├── vector_store.py  search.py  models.py
│   ├── extractors/{text,code,pdf,docx}_extractor.py
│   └── requirements.txt
├── test_files/                      # sample files to index
├── .env.example
└── setup.sh
```

## Setup

Requirements: macOS, Python 3.9+, and Xcode (for the app). On Apple Silicon all
Python wheels install prebuilt.

```bash
./setup.sh                 # creates .venv and installs helper/requirements.txt
cp .env.example .env       # then edit .env and set GEMINI_API_KEY
```

Get a key from Google AI Studio and put it in `.env`:

```
GEMINI_API_KEY=your_real_key
```

The API key is read from the environment / `.env` only — it is never hardcoded.

## Embedding model

The default is the multimodal-ready **`gemini-embedding-2`** (768 dimensions),
chosen because the app is meant to grow into images/audio/video later.

- `gemini-embedding-v1` is rejected.
- `gemini-embedding-001` is allowed **only** as an explicit text-only fallback:
  set `GEMINI_EMBEDDING_MODEL=gemini-embedding-001` **and** `TEXT_ONLY_MODE=true`.

Check what is configured:

```bash
python helper/main.py model-info
# {"status":"success","embedding_provider":"gemini","embedding_model":"gemini-embedding-2",
#  "embedding_dimensions":768,"text_only_mode":false}
```

The model + dimensions used to build the index are recorded in
`~/.semantic_file_finder/index_meta.json`. If you change the model, the existing
index becomes incompatible and `index`/`search` will return a clear error telling
you to reset and re-index — embeddings from different models are never mixed.

## Helper CLI

Activate the venv first (`source .venv/bin/activate`), or prefix commands with
`./.venv/bin/python`. Every command prints exactly one JSON object to stdout;
logs go to stderr and `~/.semantic_file_finder/logs/`.

```bash
python helper/main.py index "/path/to/folder"     # add --force to re-index unchanged files
python helper/main.py index "/path/to/folder" --progress   # stream NDJSON progress (used by the app)
python helper/main.py search "transformer attention" --limit 10
python helper/main.py status
python helper/main.py reset
python helper/main.py model-info
```

Example search output:

```json
{
  "status": "success",
  "query": "transformer attention",
  "results": [
    {
      "file_name": "attention_paper.pdf",
      "file_path": "/Users/you/Docs/attention_paper.pdf",
      "file_extension": ".pdf",
      "content_preview": "Scaled dot-product attention computes ...",
      "page_number": 2,
      "chunk_index": 1,
      "score": 0.84
    }
  ]
}
```

## Run the macOS app

**Fastest (dev):**

```bash
cd macos-app
swift run
```

**As a real .app bundle (recommended for daily use):**

```bash
brew install xcodegen
cd macos-app
xcodegen generate
open SemanticFileFinder.xcodeproj   # then Run (⌘R)
```

The app finds the helper at `helper/` next to this repo and automatically prefers
the project `.venv`. To point it elsewhere, set the `SEMANTIC_HELPER_DIR`
environment variable or the `helperDirectory` UserDefaults key. The app sandbox is
intentionally **off** for this MVP so it can run the helper and read the folder
you pick — re-enable it before any distribution.

Use it: **Choose Folder → Index** (a live progress bar shows files done /
remaining) **→ type a query → Return → Open**. Switch results between **list**
and **icon** views with the segmented control in the toolbar.

## Local storage

```
~/.semantic_file_finder/
├── index.lance/        # LanceDB database (table: chunks)
├── index_meta.json     # embedding provider/model/dimensions/created_at
├── settings.json
└── logs/
```

## Troubleshooting

- **`GEMINI_API_KEY is not set`** — add it to `.env` (needed for `index`/`search`,
  not for `status`/`model-info`/`reset`).
- **Model "not found" from the API** — confirm your key has access to
  `gemini-embedding-2`, or use the text-only fallback (`gemini-embedding-001` +
  `TEXT_ONLY_MODE=true`), then `reset` and re-index.
- **"Index was built with a different model…"** — run `python helper/main.py reset`
  then `python helper/main.py index "/path" --force`.
- **App can't find the helper** — set `SEMANTIC_HELPER_DIR` to the absolute path of
  the `helper/` directory.

## Not in this MVP (architecture kept flexible for later)

Images/OCR, audio/video, smart folders, auto-tagging, hybrid keyword+vector
search, background indexing, file-system watching, and app notarization.

## License

Released under the [MIT License](LICENSE) © 2026 aayushale001. You're free to
use, modify, and distribute it; just keep the copyright and license notice.
