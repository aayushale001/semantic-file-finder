#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HELPER_NAME="${SFF_HELPER_NAME:-fosvera-helper}"
VENV_DIR="${SFF_RELEASE_VENV:-$ROOT/.venv-release}"
PYTHON="${PYTHON:-$VENV_DIR/bin/python}"
REQUIREMENTS_LOCK="$ROOT/helper/requirements-build.txt"
SIGN_IDENTITY="${SFF_CODESIGN_IDENTITY:-}"

BUILD_DIR="$ROOT/build/pyinstaller"
PYINSTALLER_DIST="$ROOT/dist/pyinstaller"
HELPER_DIST="$ROOT/dist/helper"
GENERATED_HELPER="$PYINSTALLER_DIST/$HELPER_NAME"
HELPER_EXECUTABLE="$HELPER_DIST/$HELPER_NAME"

fail() {
  echo "❌ $*" >&2
  exit 1
}

step() {
  echo
  echo "==> $*"
}

if [[ ! -x "$PYTHON" ]]; then
  fail "Release Python not found at $PYTHON

Create it with:
  python3.12 -m venv .venv-release
  source .venv-release/bin/activate
  python -m pip install --require-hashes -r helper/requirements-build.txt"
fi

[[ -f "$REQUIREMENTS_LOCK" ]] || fail "Locked build requirements missing: $REQUIREMENTS_LOCK"

step "Installing locked helper/build dependencies"
"$PYTHON" -m pip install --require-hashes -r "$REQUIREMENTS_LOCK"

if ! "$PYTHON" -m PyInstaller --version >/dev/null 2>&1; then
  fail "PyInstaller is not installed after applying $REQUIREMENTS_LOCK"
fi

step "Cleaning previous helper build"
rm -rf "$BUILD_DIR" "$PYINSTALLER_DIST" "$HELPER_DIST"
mkdir -p "$BUILD_DIR" "$PYINSTALLER_DIST" "$ROOT/dist"

step "Building $HELPER_NAME with PyInstaller"
"$PYTHON" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name "$HELPER_NAME" \
  --paths "$ROOT/helper" \
  --collect-all lancedb \
  --collect-all lance_namespace \
  --collect-all lance_namespace_urllib3_client \
  --collect-all pyarrow \
  --collect-all imageio_ffmpeg \
  --collect-all pypdf \
  --collect-all docx \
  --collect-all lxml \
  --collect-all pydantic \
  --collect-all pydantic_core \
  --collect-submodules google.genai \
  --collect-submodules google.auth \
  --collect-submodules google.oauth2 \
  --distpath "$PYINSTALLER_DIST" \
  --workpath "$BUILD_DIR" \
  --specpath "$BUILD_DIR" \
  "$ROOT/helper/main.py"

if [[ ! -d "$GENERATED_HELPER" ]]; then
  fail "PyInstaller finished but did not create $GENERATED_HELPER"
fi

step "Moving helper bundle to dist/helper"
mv "$GENERATED_HELPER" "$HELPER_DIST"

if [[ -d "$HELPER_DIST/_internal 2" ]]; then
  step "Normalizing PyInstaller _internal directory"
  ditto "$HELPER_DIST/_internal 2" "$HELPER_DIST/_internal"
  rm -rf "$HELPER_DIST/_internal 2"
fi

if [[ ! -x "$HELPER_EXECUTABLE" ]]; then
  chmod +x "$HELPER_EXECUTABLE" 2>/dev/null || true
fi
[[ -x "$HELPER_EXECUTABLE" ]] || fail "Helper executable is missing or not executable: $HELPER_EXECUTABLE"
[[ -f "$HELPER_DIST/_internal/Python" ]] || fail "Python runtime missing from $HELPER_DIST/_internal"

if [[ -n "$SIGN_IDENTITY" ]]; then
  command -v codesign >/dev/null 2>&1 || fail "codesign is required when SFF_CODESIGN_IDENTITY is set"
  command -v file >/dev/null 2>&1 || fail "file is required when SFF_CODESIGN_IDENTITY is set"
  step "Signing helper frameworks"
  while IFS= read -r -d '' framework; do
    echo "Signing ${framework#$ROOT/}"
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$framework"
  done < <(find "$HELPER_DIST" -type d -name "*.framework" -print0)

  step "Signing helper Mach-O files"
  while IFS= read -r -d '' candidate; do
    case "$candidate" in
      *.framework/*) continue ;;
    esac
    if file -b "$candidate" | grep -q "Mach-O"; then
      echo "Signing ${candidate#$ROOT/}"
      codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$candidate"
    fi
  done < <(find "$HELPER_DIST" -type f -print0)

  codesign --verify --deep --strict --verbose=2 "$HELPER_EXECUTABLE"
  codesign --display --verbose=4 "$HELPER_EXECUTABLE" 2>/tmp/fosvera-helper-codesign-display.txt || true
  if ! awk -F= '/^TeamIdentifier=/{found=1} END{exit(found ? 0 : 1)}' /tmp/fosvera-helper-codesign-display.txt; then
    fail "Helper executable was signed but has no TeamIdentifier. Check SFF_CODESIGN_IDENTITY."
  fi
else
  echo
  echo "⚠️  Helper bundle was not signed. For release builds run:"
  echo "   SFF_CODESIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID)\" ./scripts/build-helper.sh"
fi

step "Smoke-testing frozen helper"
env -u GEMINI_API_KEY SFF_LOAD_DOTENV=0 "$HELPER_EXECUTABLE" model-info >/tmp/fosvera-helper-model-info.json
env -u GEMINI_API_KEY SFF_LOAD_DOTENV=0 "$HELPER_EXECUTABLE" status >/tmp/fosvera-helper-status.json

echo "✅ Helper built successfully:"
echo "   $HELPER_DIST"
echo
echo "Quick dev test with swift run:"
echo "  FOSVERA_HELPER_DIR=\"$HELPER_DIST\" swift run --package-path macos-app"
echo
echo "Bundled .app test:"
echo "  (cd macos-app && xcodegen generate)"
echo "  xcodebuild -project macos-app/Fosvera.xcodeproj -scheme Fosvera -configuration Debug -derivedDataPath build/xcode CODE_SIGNING_ALLOWED=NO build"
