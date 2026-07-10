# Changelog

All notable user-facing changes should be recorded here.

This project loosely follows [Keep a Changelog](https://keepachangelog.com/) and
uses semantic-ish versions while the MVP is still moving quickly.

## [0.1.0] - Unreleased

### Added

- Native SwiftUI macOS app.
- Bring-your-own Gemini API key flow with Keychain storage.
- Gemini-backed semantic indexing and search.
- Multimodal indexing for text, code, PDFs, DOCX, images, audio, and video.
- Auto / All / Documents / Images / Audio / Video search scopes.
- Indexed-file gallery for the default home view.
- Offline browsing of already indexed files.
- Offline filename/path/text search fallback when Gemini is unreachable.
- Help screen explaining the app flow.
- Standalone frozen helper bundled into the app, so users do not need Python
  installed.
- Release preparation docs for privacy, uninstall, checksums, signing, and
  notarization.

### Known limitations

- Semantic search and indexing new files require internet access.
- OCR for text inside images and scanned PDFs is not implemented yet.
- The Mac App Store path will require a future sandbox/security-scoped-bookmark
  pass.
