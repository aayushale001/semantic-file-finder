#!/usr/bin/env bash
# Build a signed, exported macOS .app that contains the frozen Python helper.
#
# Prerequisite: build and Developer-ID-sign dist/helper first:
#   SFF_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     ./scripts/build-helper.sh
#
# Typical local final-bundle test:
#   SFF_OPEN_APP=1 ./scripts/build-app.sh
#
# Set SFF_APP_OUTPUT_DIR to choose a stable output directory. The default is a
# timestamped local-cache folder so Desktop/iCloud Finder metadata cannot poison
# the signed app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT_DIR="$ROOT/macos-app"
PROJECT="$PROJECT_DIR/Fosvera.xcodeproj"
PROJECT_SPEC="$PROJECT_DIR/project.yml"
EXPORT_OPTIONS="$PROJECT_DIR/ExportOptions-DeveloperID.plist"
SCHEME="${SFF_APP_SCHEME:-Fosvera}"
CONFIGURATION="Release"
HELPER_NAME="${SFF_HELPER_NAME:-fosvera-helper}"
HELPER="$ROOT/dist/helper/$HELPER_NAME"
OUTPUT_DIR="${SFF_APP_OUTPUT_DIR:-$HOME/Library/Caches/Fosvera/builds/final-bundle-$(date +%Y%m%d-%H%M%S)}"
ARCHIVE_PATH="$OUTPUT_DIR/$SCHEME.xcarchive"
EXPORT_PATH="$OUTPUT_DIR/export"
OPEN_APP="${SFF_OPEN_APP:-0}"

fail() {
  echo "❌ $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-app.sh [--open]

Builds a Developer ID-signed Release archive and exports a standalone .app.

Environment variables:
  SFF_APP_OUTPUT_DIR    Output directory (default: ~/Library/Caches/Fosvera/builds/final-bundle-<timestamp>)
  SFF_EXPECTED_TEAM_ID  Require this Apple Developer Team ID
  SFF_OPEN_APP=1        Open the exported app after a successful build
  SFF_APP_SCHEME        Xcode scheme (default: Fosvera)
EOF
}

case "${1:-}" in
  "") ;;
  --open) OPEN_APP=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; fail "Unknown option: $1" ;;
esac

for command in xcodegen xcodebuild codesign xattr; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

[[ -f "$PROJECT_SPEC" ]] || fail "XcodeGen spec is missing: $PROJECT_SPEC"
[[ -f "$EXPORT_OPTIONS" ]] || fail "Developer ID export options are missing: $EXPORT_OPTIONS"
[[ -x "$HELPER" ]] || fail "Frozen helper is missing: $HELPER\nRun ./scripts/build-helper.sh first."

project_team_id="$(awk -F: '/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' "$PROJECT_SPEC")"
[[ -n "$project_team_id" ]] || fail "DEVELOPMENT_TEAM is missing from $PROJECT_SPEC"
expected_team_id="${SFF_EXPECTED_TEAM_ID:-$project_team_id}"

signing_info="$(codesign --display --verbose=4 "$HELPER" 2>&1 || true)"
helper_team_id="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$signing_info" | tail -1)"
if [[ -z "$helper_team_id" || "$helper_team_id" == "not set" ]]; then
  fail "Frozen helper is ad-hoc signed or missing a TeamIdentifier. Rebuild it with SFF_CODESIGN_IDENTITY."
fi
[[ "$helper_team_id" == "$expected_team_id" ]] || fail "Frozen helper TeamIdentifier '$helper_team_id' does not match expected team '$expected_team_id'"
codesign --verify --deep --strict --verbose=2 "$HELPER"

if [[ -e "$ARCHIVE_PATH" || -e "$EXPORT_PATH" ]]; then
  fail "Build output already exists under $OUTPUT_DIR. Choose another SFF_APP_OUTPUT_DIR so no existing artifact is overwritten."
fi
mkdir -p "$OUTPUT_DIR"

step "Generating Xcode project"
(
  cd "$PROJECT_DIR"
  xcodegen generate
)

step "Archiving signed Release app"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH"

step "Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

shopt -s nullglob
apps=("$EXPORT_PATH"/*.app)
shopt -u nullglob
[[ "${#apps[@]}" -eq 1 ]] || fail "Expected exactly one exported .app in $EXPORT_PATH"
APP_PATH="${apps[0]}"
BUNDLED_HELPER="$APP_PATH/Contents/Resources/helper/$HELPER_NAME"

step "Removing extended attributes from exported app"
# Finder metadata (for example, com.apple.FinderInfo) makes codesign reject an
# otherwise valid app bundle. Xcode can carry this metadata into an export, so
# remove it before the strict verification below and before notarization. The
# root bundle's FinderInfo needs an explicit deletion on recent macOS releases.
xattr -cr "$APP_PATH"
xattr -d com.apple.FinderInfo "$APP_PATH" 2>/dev/null || true
xattr -d com.apple.ResourceFork "$APP_PATH" 2>/dev/null || true
if xattr -lr "$APP_PATH" 2>/dev/null | grep -qE 'com\.apple\.(FinderInfo|ResourceFork)'; then
  fail "Exported app retains Finder metadata. Set SFF_APP_OUTPUT_DIR outside Desktop, iCloud Drive, or another synced folder."
fi

step "Verifying exported app and bundled helper"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
[[ -x "$BUNDLED_HELPER" ]] || fail "Bundled helper is missing: $BUNDLED_HELPER"
codesign --verify --deep --strict --verbose=2 "$BUNDLED_HELPER"
env -u GEMINI_API_KEY SFF_LOAD_DOTENV=0 "$BUNDLED_HELPER" model-info >/dev/null

app_signing_info="$(codesign --display --verbose=4 "$APP_PATH" 2>&1 || true)"
app_team_id="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$app_signing_info" | tail -1)"
[[ "$app_team_id" == "$expected_team_id" ]] || fail "Exported app TeamIdentifier '$app_team_id' does not match expected team '$expected_team_id'"

bundled_signing_info="$(codesign --display --verbose=4 "$BUNDLED_HELPER" 2>&1 || true)"
bundled_team_id="$(awk -F= '/^TeamIdentifier=/{print $2}' <<<"$bundled_signing_info" | tail -1)"
[[ "$bundled_team_id" == "$expected_team_id" ]] || fail "Bundled helper TeamIdentifier '$bundled_team_id' does not match expected team '$expected_team_id'"

echo
echo "✅ Signed app exported successfully:"
echo "   $APP_PATH"
echo
echo "This is a bundled-app test build. Notarize and staple it before public distribution."

if [[ "$OPEN_APP" == "1" ]]; then
  step "Opening exported app"
  open "$APP_PATH"
fi
