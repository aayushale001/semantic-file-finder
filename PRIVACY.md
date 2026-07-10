# Privacy Policy

Fosvera is a local-first macOS app. It does not run a hosted backend
for this project and does not include a shared Gemini API key.

## What stays on your Mac

- Your search index is stored locally at `~/.semantic_file_finder/`. This stable
  legacy path is retained so existing tester indexes survive the Fosvera rebrand.
- Your watched-folder settings and helper logs are stored locally.
- Your Gemini API key is stored in the macOS Keychain under:
  - service: `com.semanticfilefinder.app.gemini-api-key`
  - account: `gemini-api-key`

The app does not add analytics, telemetry, crash reporting, or advertising SDKs.

## What is sent to Google Gemini

When you index or semantically search files, the app talks directly to Google's
Gemini API using the API key you provide:

- During indexing, supported file content or media segments are sent to Gemini to
  create embeddings.
- During semantic search, your search text is sent to Gemini to create a query
  embedding.
- For ambiguous Auto-scope searches, the query text may be sent to a Gemini
  generation model to infer whether you likely meant documents, images, audio, or
  video.

Your usage counts against your own Google project quota/billing. Review Google's
Gemini API and AI Studio terms for how Google handles data sent to its API.

## Offline behavior

When Gemini is unreachable or your Mac is offline, the app can still browse
already indexed files and fall back to local filename/path/text search. Offline
fallback search does not call Gemini.

Indexing new files and semantic searches need internet access because embeddings
are created by Gemini.

## How to delete your data

See [docs/UNINSTALL.md](docs/UNINSTALL.md) for the full uninstall flow,
including deleting the local index and removing the Gemini API key from Keychain.
