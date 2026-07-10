#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0

fail() {
  echo "❌ $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "✅ $*"
}

warn() {
  echo "⚠️  $*"
}

require_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    pass "$path exists"
  else
    fail "$path is missing"
  fi
}

require_command() {
  local command="$1"
  if command -v "$command" >/dev/null 2>&1; then
    pass "$command is installed"
  else
    fail "$command is not installed"
  fi
}

contains() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -q -- "$pattern" "$@"
  else
    grep -R -q -E -- "$pattern" "$@"
  fi
}

contains_i() {
  local pattern="$1"
  shift
  if command -v rg >/dev/null 2>&1; then
    rg -qi -- "$pattern" "$@"
  else
    grep -R -q -i -E -- "$pattern" "$@"
  fi
}

require_file README.md
require_file LICENSE
require_file PRIVACY.md
require_file SECURITY.md
require_file CHANGELOG.md
require_file docs/RELEASE.md
require_file docs/GEMINI_API_KEY.md
require_file docs/UNINSTALL.md
require_file scripts/build-helper.sh
require_file scripts/build-app.sh
require_file macos-app/ExportOptions-DeveloperID.plist

require_command git
if command -v rg >/dev/null 2>&1; then
  pass "rg is installed"
else
  warn "rg is not installed; using grep fallback"
fi
require_command shasum
require_command codesign
require_command file
require_command xcodebuild
require_command xcodegen
require_file helper/requirements.in
require_file helper/requirements.txt
require_file helper/requirements-build.in
require_file helper/requirements-build.txt

tracked_dotenv_files="$(git ls-files | awk '$0 ~ /(^|\/)\.env($|\.)/ && $0 !~ /(^|\/)\.env\.example$/ { print }')"
if [[ -n "$tracked_dotenv_files" ]]; then
  echo "$tracked_dotenv_files" >&2
  fail "dotenv secret file(s) are tracked by Git; remove them from the index before release"
else
  pass "dotenv secret files are not tracked"
fi

if git grep -IlE 'AIza[0-9A-Za-z_-]{20,}|AQ\.[0-9A-Za-z_-]{30,}' -- . ':!.env.example' >/tmp/fosvera-gemini-secret-files.txt; then
  cat /tmp/fosvera-gemini-secret-files.txt >&2
  fail "possible Gemini API key literal found in tracked files"
else
  pass "no Gemini API key literals found in tracked files"
fi

if contains '--password' docs/RELEASE.md; then
  fail "docs/RELEASE.md still documents a notarization password on the command line"
else
  pass "release docs avoid command-line notarization passwords"
fi

if contains '--hash=sha256:' helper/requirements.txt \
   && contains '--hash=sha256:' helper/requirements-build.txt; then
  pass "Python runtime/build requirements are hash locked"
else
  fail "Python requirements lock files are missing hashes"
fi

if contains_i '(^pymupdf\b|\bfitz\b|collect-all fitz|PyMuPDF)' \
  helper scripts/build-helper.sh setup.sh README.md; then
  fail "PyMuPDF/Fitz is still present in helper or release scripts"
else
  pass "PyMuPDF/Fitz is not used by helper release path"
fi

if git diff --check >/tmp/fosvera-diff-check.txt; then
  pass "no whitespace errors in the working tree diff"
else
  cat /tmp/fosvera-diff-check.txt >&2
  fail "git diff --check found whitespace errors"
fi

if [[ -z "$(git status --porcelain)" ]]; then
  pass "working tree is clean"
else
  fail "working tree is dirty; commit or stash changes before cutting a release"
fi

if contains "ENABLE_HARDENED_RUNTIME: YES" macos-app/project.yml; then
  pass "Release Hardened Runtime is configured"
else
  fail "Release Hardened Runtime is not configured in macos-app/project.yml"
fi

project_team_id="$(awk -F: '/^[[:space:]]*DEVELOPMENT_TEAM:[[:space:]]*/ {gsub(/[[:space:]]/, "", $2); print $2; exit}' macos-app/project.yml)"
if [[ -z "$project_team_id" ]]; then
  fail "DEVELOPMENT_TEAM is missing from macos-app/project.yml; signed archives will not be reproducible"
elif [[ -n "${SFF_EXPECTED_TEAM_ID:-}" && "$project_team_id" != "$SFF_EXPECTED_TEAM_ID" ]]; then
  fail "project DEVELOPMENT_TEAM '$project_team_id' does not match SFF_EXPECTED_TEAM_ID '$SFF_EXPECTED_TEAM_ID'"
else
  pass "project uses Developer Team $project_team_id"
fi

if contains "com.apple.security.app-sandbox" macos-app/Fosvera.entitlements; then
  pass "entitlements file is present"
else
  warn "no app sandbox entitlement found; direct Developer ID releases can be unsandboxed"
fi

if contains "fosvera-helper" macos-app/Fosvera/Services/HelperService.swift; then
  pass "app can discover a bundled release helper executable"
else
  fail "app does not appear to know about the bundled release helper"
fi

if contains "Copy Frozen Helper" macos-app/project.yml && contains "UNLOCALIZED_RESOURCES_FOLDER_PATH.*/helper" macos-app/project.yml; then
  pass "Xcode project spec copies the frozen helper into the app bundle"
else
  fail "macos-app/project.yml does not copy the frozen helper into the app bundle"
fi

if [[ -x dist/helper/fosvera-helper ]]; then
  pass "frozen helper exists at dist/helper/fosvera-helper"
else
  fail "frozen helper is missing; run ./scripts/build-helper.sh before release"
fi

if [[ -d "dist/helper/_internal 2" ]]; then
  fail "frozen helper has a stray '_internal 2' directory; rerun ./scripts/build-helper.sh"
fi

if [[ -x dist/helper/fosvera-helper ]]; then
  if codesign --verify --deep --strict --verbose=2 dist/helper/fosvera-helper >/tmp/fosvera-helper-codesign-verify.txt 2>&1; then
    pass "frozen helper code signature verifies strictly"
  else
    cat /tmp/fosvera-helper-codesign-verify.txt >&2
    fail "frozen helper is not strictly code signed"
  fi

  invalid_framework_count=0
  while IFS= read -r -d '' framework; do
    if ! codesign --verify --deep --strict --verbose=2 "$framework" >/tmp/fosvera-framework-codesign-verify.txt 2>&1; then
      echo "Invalid helper framework signature: $framework" >&2
      cat /tmp/fosvera-framework-codesign-verify.txt >&2
      invalid_framework_count=$((invalid_framework_count + 1))
    fi
  done < <(find dist/helper -type d -name "*.framework" -print0)
  if [[ "$invalid_framework_count" -eq 0 ]]; then
    pass "all frozen helper frameworks have valid signatures"
  else
    fail "$invalid_framework_count frozen helper framework(s) are unsigned or invalid"
  fi

  unsigned_macho_count=0
  while IFS= read -r -d '' candidate; do
    case "$candidate" in
      *.framework/*) continue ;;
    esac
    if file -b "$candidate" | grep -q "Mach-O"; then
      if ! codesign --verify --strict --verbose=2 "$candidate" >/tmp/fosvera-macho-codesign-verify.txt 2>&1; then
        echo "Unsigned or invalid helper Mach-O: $candidate" >&2
        cat /tmp/fosvera-macho-codesign-verify.txt >&2
        unsigned_macho_count=$((unsigned_macho_count + 1))
      fi
    fi
  done < <(find dist/helper -type f -print0)
  if [[ "$unsigned_macho_count" -eq 0 ]]; then
    pass "all frozen helper Mach-O files have valid signatures"
  else
    fail "$unsigned_macho_count frozen helper Mach-O file(s) are unsigned or invalid"
  fi

  codesign --display --verbose=4 dist/helper/fosvera-helper >/tmp/fosvera-helper-codesign-display.txt 2>&1 || true
  helper_team_id="$(awk -F= '/^TeamIdentifier=/{print $2}' /tmp/fosvera-helper-codesign-display.txt | tail -1)"
  if [[ -z "$helper_team_id" || "$helper_team_id" == "not set" ]]; then
    fail "frozen helper is ad-hoc signed or missing a Developer ID team identifier"
  elif [[ -n "${SFF_EXPECTED_TEAM_ID:-}" && "$helper_team_id" != "$SFF_EXPECTED_TEAM_ID" ]]; then
    fail "frozen helper TeamIdentifier '$helper_team_id' does not match SFF_EXPECTED_TEAM_ID '$SFF_EXPECTED_TEAM_ID'"
  else
    pass "frozen helper has signing TeamIdentifier $helper_team_id"
  fi

  if env -u GEMINI_API_KEY SFF_LOAD_DOTENV=0 dist/helper/fosvera-helper model-info >/tmp/fosvera-preflight-model-info.json; then
    pass "frozen helper launches"
  else
    fail "frozen helper failed to launch"
  fi
fi

if swift build --package-path macos-app >/dev/null; then
  pass "Swift package builds"
else
  fail "Swift package build failed"
fi

PYTHON="${PYTHON:-python3}"
if "$PYTHON" -m compileall -q helper; then
  pass "Python helper compiles"
else
  fail "Python helper compile check failed"
fi

echo
if [[ "$failures" -eq 0 ]]; then
  echo "Release preflight passed."
else
  echo "Release preflight failed with $failures issue(s)." >&2
  exit 1
fi
