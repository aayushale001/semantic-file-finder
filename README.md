# Fosvera

A native macOS app that indexes one or more folders of your files and lets you
search them by **meaning** instead of filename — across text **and media**. A SwiftUI front
end drives a small Python helper that embeds everything with **Gemini Embedding 2**
and stores the vectors in a local **LanceDB** database. Because Gemini Embedding 2
is natively multimodal, text, images, audio, and video all land in the **same
vector space**, so a typed query like "sunset over the ocean" can match a photo or
a video clip. Text and media occupy different regions of that space, so search
defaults to an **Auto** scope: it reads keyword cues first (and, only for less
obvious queries, a quick Gemini call) to infer the kind you mean (e.g. "sunset over
the ocean" → Images), and blends the top matches from every kind when the query is
ambiguous so media is never buried. You can also pick a kind manually (All /
Documents / Images / Audio / Video). The index is stored locally; embedding calls
for indexing and semantic search go directly to the Gemini API using your key.
When Gemini is unreachable, the app falls back to local filename/path/text search
over files that have already been indexed.

Supported files:
- **Text & docs**: `.txt` `.md` `.pdf` `.docx`
- **Code**: `.py` `.js` `.ts` `.tsx` `.jsx` `.cpp` `.c` `.h` `.hpp` `.java` `.html` `.css` `.json`
- **Images**: `.jpg` `.jpeg` `.png`
- **Audio**: `.mp3` `.wav`  ·  **Video**: `.mp4` `.mov`

## Download / release status

Signed public builds are not published yet. The planned first public release path
is a GitHub Release with a Developer ID signed, notarized `.dmg` plus
`SHA256SUMS.txt`.

Maintainer release docs:

- [GitHub release guide](docs/RELEASE.md)
- [Privacy policy](PRIVACY.md)
- [Gemini API key setup](docs/GEMINI_API_KEY.md)
- [Uninstall and delete local data](docs/UNINSTALL.md)
- [Security policy](SECURITY.md)

Text/docs/code are extracted and chunked; images/audio/video are embedded directly
as media. To stay fast on big files, video is sampled into evenly-spaced still
frames and long audio into clips (both capped), so even a feature-length movie
indexes in a bounded number of small embeddings — with live per-file progress.
When nothing is searched, the app shows your **indexed files as a gallery** with
thumbnails, switchable between list and icon views.

## Architecture

```
SwiftUI macOS App  ──keeps alive──▶  Python helper server (JSON lines over stdin/stdout)
                                        │
                  scan ▶ extract ▶ chunk ▶ Gemini Embedding 2 ▶ LanceDB
                                                                    │
SwiftUI results  ◀────────────────  JSON  ◀─────────────────────────┘
```

Gemini creates embeddings and, for unclear Auto-scope queries, helps classify
intent. LanceDB stores and searches the local index. SwiftUI handles UI and calls
the helper.

The app keeps **one persistent helper process** (`main.py serve`) alive for
interactive commands — search, browsing, status — so the Python interpreter,
Gemini client, and LanceDB connection stay warm and a search costs ~1 ms of
transport instead of ~1 s of process startup. Indexing runs in its own one-shot
subprocess so a long background index never blocks a search; the same commands
also exist as a plain CLI for scripting and debugging.

## Project structure

```
.
├── macos-app/
│   ├── Package.swift                # swift run (fastest dev path)
│   ├── project.yml                  # XcodeGen spec for a real .app
│   ├── Fosvera.entitlements
│   └── Fosvera/
│       ├── FosveraApp.swift
│       ├── ContentView.swift
│       ├── Models/SearchResult.swift
│       ├── Services/HelperService.swift
│       └── Views/{FolderPickerView,HelpView,IndexedFilesView,IndexingView,LiquidGlass,SearchBar,SearchResultsView}.swift
├── helper/
│   ├── main.py                      # Typer CLI: index / search / local-search / list / status / reset / model-info
│   ├── config.py  scanner.py  chunker.py  embeddings.py
│   ├── vector_store.py  search.py  models.py
│   ├── extractors/{text,code,pdf,docx}_extractor.py
│   └── requirements.txt
├── test_files/                      # sample files to index
├── docs/{RELEASE,GEMINI_API_KEY,UNINSTALL}.md
├── scripts/{build-helper,build-app,release-preflight,checksums}.sh
├── .env.example
├── PRIVACY.md  SECURITY.md  CHANGELOG.md  LICENSE
└── setup.sh
```

## Setup

Requirements: macOS, Python 3.9+, and Xcode (for the app). On Apple Silicon all
Python wheels install prebuilt.

```bash
./setup.sh                 # creates .venv and installs helper/requirements.txt
```

**API key — bring your own.** The app runs on *your* Gemini API key, so usage
counts against your own Google project quota/billing, not this open-source
project. Google offers a Gemini API free tier for getting started. On first
launch the app walks you through it: create or copy a key at
[Google AI Studio](https://aistudio.google.com/apikey), paste it into the app's
Settings, and **Save & Test** validates it with a lightweight `models.list`
metadata call and stores it in the **macOS Keychain** — never in a plaintext
file.

Detailed setup, rotation, and removal steps are in
[docs/GEMINI_API_KEY.md](docs/GEMINI_API_KEY.md).

For CLI use you can instead put the key in a `.env` at the repo root
(`cp .env.example .env`, then set `GEMINI_API_KEY`). The macOS app ignores
`.env` by default and uses the Keychain key saved from Settings, so release users
do not accidentally inherit a developer key. During local development only, you
can opt back into environment/`.env` keys by launching the app with
`SFF_ALLOW_APP_ENV_API_KEY=1`.

## Embedding model

The default is the multimodal-ready **`gemini-embedding-2`** (768 dimensions),
used for text, code, documents, images, audio, and video.

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
python helper/main.py search "people smiling" --scope images   # restrict to a kind: documents|images|audio|video
python helper/main.py local-search "invoice pdf" --scope documents  # offline filename/text search
python helper/main.py list                          # distinct files in the index (powers the gallery)
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
open Fosvera.xcodeproj   # then Run (⌘R)
```

The app finds the helper at `helper/` next to this repo and automatically prefers
the project `.venv`. For releases, the app first looks for a bundled helper at
`Contents/Resources/helper/fosvera-helper`; for development, set the
`FOSVERA_HELPER_DIR` environment variable or the `helperDirectory` UserDefaults
key if your helper lives somewhere custom. The App Store sandbox is intentionally
**off** in this development build so it can run the helper and read the folder you
pick; the direct GitHub release path uses Developer ID signing/notarization first,
with App Store sandboxing left for a later pass.

Use it: **Add Folder → Index All** (a live progress bar shows files done /
remaining) **→ type a query → Return → Open**. You can watch multiple folders;
the app auto-syncs changes in the background and lets you remove a watched
folder from the index later. Switch results between **list** and **icon** views
with the segmented control in the toolbar.

If you are offline, already-indexed files still appear and searches fall back to
local filename/path/text matching. Semantic search and indexing new content need
internet access because Gemini creates embeddings for your files and queries.

## Local storage

The Fosvera rebrand intentionally keeps this established local directory so
existing tester indexes remain available.

```
~/.semantic_file_finder/
├── index.lance/        # LanceDB database (table: chunks)
├── index_meta.json     # embedding provider/model/dimensions/created_at
└── logs/
```

To fully uninstall the app, delete the index, and remove the Keychain API key,
follow [docs/UNINSTALL.md](docs/UNINSTALL.md).

## Privacy and security

Fosvera is local-first, but semantic indexing/search calls Gemini
directly with your API key. During indexing, supported file content or media
segments are sent to Gemini to create embeddings. During semantic search, your
query text is sent to Gemini to create the query embedding. The local index stays
on your Mac.

Read the full [privacy policy](PRIVACY.md) and [security policy](SECURITY.md)
before publishing a public build.

## Troubleshooting

- **"No Gemini API key is configured"** — paste your key in the app's Settings
  (gear icon). For CLI use, add it to `.env` (needed for `index`/`search`,
  not for `status`/`model-info`/`reset`). Validate with
  `python helper/main.py check-key`.
- **Model "not found" from the API** — confirm your key has access to
  `gemini-embedding-2`, or use the text-only fallback (`gemini-embedding-001` +
  `TEXT_ONLY_MODE=true`), then `reset` and re-index.
- **"Index was built with a different model…"** — run `python helper/main.py reset`
  then `python helper/main.py index "/path" --force`.
- **No internet / Gemini unreachable** — already-indexed files remain browseable,
  and search falls back to local filename/path/text matching. Indexing and
  semantic search resume when internet access is back.
- **App can't find the helper** — set `FOSVERA_HELPER_DIR` to the absolute path of
  the `helper/` directory.
- **Want to fully uninstall** — see [docs/UNINSTALL.md](docs/UNINSTALL.md).

## Current limitations / roadmap

The app already supports text, code, PDFs, DOCX, images, audio, video, scoped
semantic search, Auto scope detection, indexed-file browsing, and offline local
filename/text fallback. Still planned:

- OCR for text inside images and scanned PDFs.
- Smart folders, saved searches, and auto-tagging.
- More granular per-file incremental indexing for very large watched folders.
- Optional hybrid keyword + semantic scoring for online search.
- App Store sandboxing with security-scoped bookmarks, if an App Store release is
  pursued later.

## License

Released under the [MIT License](LICENSE) © 2026 aayushale001. You're free to
use, modify, and distribute it; just keep the copyright and license notice.
