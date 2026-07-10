# GitHub Release Guide

This guide is for a direct macOS release through GitHub Releases using Apple
Developer ID signing and notarization.

Recommended first public path: **GitHub Releases first, Mac App Store later**.
The App Store path needs a separate sandboxing pass. A direct Developer ID
release can be notarized without the Mac App Store sandbox.

## Current release readiness

Before publishing `v0.1.0`, finish the standalone helper packaging:

- The app now knows how to prefer a bundled helper at
  `Contents/Resources/helper/fosvera-helper`.
- Development still works from source through `helper/main.py`.
- A public download should not require users to install Python, clone the repo,
  create `.venv`, or set `FOSVERA_HELPER_DIR`.

Do not publish a “normal user” binary until the helper/runtime is bundled and the
download has been tested on a clean Mac user account.

Expected release bundle shape:

```text
Fosvera.app/
└── Contents/
    └── Resources/
        └── helper/
            └── fosvera-helper   # preferred standalone helper executable
```

The app also supports a bundled source-helper layout if you include a Python
runtime:

```text
Fosvera.app/
└── Contents/
    └── Resources/
        ├── python/bin/python3
        └── helper/main.py
```

For the first public release, prefer the standalone helper executable because it
keeps the user install simple and avoids depending on the user's system Python.
Any bundled helper/runtime must be signed before the outer app is signed,
archived, and notarized.

## Prerequisites

- Apple Developer Program membership.
- Xcode and command line tools.
- A Developer ID Application certificate installed in Keychain.
- XcodeGen:

```bash
brew install xcodegen
```

- Stored notarization credentials:

```bash
xcrun notarytool store-credentials "fosvera-notary" \
  --apple-id "you@example.com" \
  --team-id "YOUR_TEAM_ID"
```

Enter the app-specific password at the secure prompt. Do not pass notarization
passwords on the command line or store them in shell history.

Apple references:

- [Developer ID](https://developer.apple.com/developer-id/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 1. Prepare the release

Update the version in `macos-app/project.yml`:

```yaml
MARKETING_VERSION: "0.1.0"
CURRENT_PROJECT_VERSION: "1"
```

Update:

- `CHANGELOG.md`
- `README.md`
- `PRIVACY.md`, if data behavior changed
- `docs/UNINSTALL.md`, if storage paths changed

Build the frozen helper:

```bash
SFF_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-helper.sh
```

This creates:

```text
dist/helper/fosvera-helper
```

Smoke-test the helper directly:

```bash
dist/helper/fosvera-helper model-info
dist/helper/fosvera-helper status
```

Run the preflight:

```bash
SFF_EXPECTED_TEAM_ID="TEAMID" ./scripts/release-preflight.sh
```

The preflight intentionally fails on a dirty Git tree. Commit release changes
first, then run it again.

The helper build script installs Python dependencies from
`helper/requirements-build.txt`, a hash-locked file generated from
`helper/requirements-build.in`. Runtime dependencies are locked in
`helper/requirements.txt` from `helper/requirements.in`.

To refresh locks intentionally:

```bash
python -m pip install pip-tools
python -m piptools compile --generate-hashes \
  --output-file helper/requirements.txt \
  helper/requirements.in
python -m piptools compile --generate-hashes \
  --output-file helper/requirements-build.txt \
  helper/requirements-build.in
```

Review the diff before committing a lock refresh.

## 2. Generate the Xcode project

```bash
cd macos-app
xcodegen generate
```

XcodeGen adds a **Copy Frozen Helper** build phase. During an Xcode build, that
phase copies:

```text
../dist/helper
```

into:

```text
Fosvera.app/Contents/Resources/helper
```

Build a local unsigned Debug app and verify the bundled helper:

```bash
cd ..
xcodebuild \
  -project macos-app/Fosvera.xcodeproj \
  -scheme Fosvera \
  -configuration Debug \
  -derivedDataPath build/xcode \
  CODE_SIGNING_ALLOWED=NO \
  build

build/xcode/Build/Products/Debug/Fosvera.app/Contents/Resources/helper/fosvera-helper model-info
```

Open the project once and confirm:

- Team is set to your Apple Developer team.
- Bundle identifier is unique.
- Release configuration has Hardened Runtime enabled.
- The app launches from Xcode without `FOSVERA_HELPER_DIR`.

## 3. Archive and export a Developer ID build

For a signed, bundled-app test build, use the script from the repo root:

```bash
SFF_OPEN_APP=1 ./scripts/build-app.sh
```

It verifies the signed frozen helper, regenerates the Xcode project, archives
the Release app, exports it, verifies both signatures, and opens the final
`.app`. By default, output goes to a timestamped local-cache directory under
`~/Library/Caches/Fosvera/builds/`, avoiding Finder metadata from Desktop/iCloud
that can invalidate a code signature. Set `SFF_APP_OUTPUT_DIR` to a local,
non-synced directory if you want a specific location:

```bash
SFF_APP_OUTPUT_DIR="$HOME/Developer/Fosvera-release-v0.1.0" ./scripts/build-app.sh
```

The script is the preferred path so you do not need to remember Xcode's archive
and export arguments. The manual equivalent is below for troubleshooting. If
your repository is in Desktop, iCloud Drive, or another synced folder, use a
local non-synced release directory instead of `dist/`:

```bash
mkdir -p dist

xcodebuild archive \
  -project macos-app/Fosvera.xcodeproj \
  -scheme Fosvera \
  -configuration Release \
  -archivePath dist/Fosvera.xcarchive

xcodebuild -exportArchive \
  -archivePath dist/Fosvera.xcarchive \
  -exportPath dist/export \
  -exportOptionsPlist macos-app/ExportOptions-DeveloperID.plist
```

The exported app should be at:

```text
dist/export/Fosvera.app
```

Depending on Xcode's product naming, it may instead export as
`Fosvera.app`. Use the actual path in the next commands.

## 4. Verify signing locally

```bash
codesign --verify --deep --strict --verbose=2 "dist/export/Fosvera.app"
spctl --assess --type execute --verbose=4 "dist/export/Fosvera.app"
```

If the app contains a bundled helper executable, also inspect it:

```bash
codesign --verify --deep --strict --verbose=2 \
  "dist/export/Fosvera.app/Contents/Resources/helper/fosvera-helper"

codesign --display --verbose=4 \
  "dist/export/Fosvera.app/Contents/Resources/helper/fosvera-helper"
```

## 5. Notarize and staple

Zip the app for notarization:

```bash
ditto -c -k --keepParent \
  "dist/export/Fosvera.app" \
  "dist/Fosvera-notarization.zip"
```

Submit and wait:

```bash
xcrun notarytool submit "dist/Fosvera-notarization.zip" \
  --keychain-profile "fosvera-notary" \
  --wait
```

Staple the ticket to the app:

```bash
xcrun stapler staple "dist/export/Fosvera.app"
xcrun stapler validate "dist/export/Fosvera.app"
```

## 6. Create and notarize the DMG

```bash
hdiutil create \
  -volname "Fosvera" \
  -srcfolder "dist/export/Fosvera.app" \
  -ov \
  -format UDZO \
  "dist/Fosvera-0.1.0.dmg"
```

Notarize and staple the DMG too:

```bash
xcrun notarytool submit "dist/Fosvera-0.1.0.dmg" \
  --keychain-profile "fosvera-notary" \
  --wait

xcrun stapler staple "dist/Fosvera-0.1.0.dmg"
xcrun stapler validate "dist/Fosvera-0.1.0.dmg"
```

## 7. Generate checksums

```bash
./scripts/checksums.sh dist/Fosvera-0.1.0.dmg > dist/SHA256SUMS.txt
```

Upload both files to GitHub Releases:

- `Fosvera-0.1.0.dmg`
- `SHA256SUMS.txt`

Users can verify with:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

## 8. Draft the GitHub release

Use the matching Git tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Release notes should include:

- What changed, copied from `CHANGELOG.md`.
- Supported macOS version.
- That users need their own Gemini API key.
- Link to `PRIVACY.md`.
- Link to `docs/GEMINI_API_KEY.md`.
- Link to `docs/UNINSTALL.md`.
- Known limitations.

## Final smoke test

Before publishing, download the DMG from the draft release on a clean Mac user
account and verify:

- Gatekeeper opens the app without a scary unsigned-app warning.
- First-run API key setup works.
- API key is stored in Keychain.
- Adding a folder works.
- Indexing works.
- Relaunch shows already indexed files.
- Offline local search works.
- Uninstall instructions remove the index and key.
