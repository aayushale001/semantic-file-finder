#!/usr/bin/env bash
# Create the Python virtualenv and install helper dependencies.
set -euo pipefail
cd "$(dirname "$0")"

PYTHON="${PYTHON:-python3}"

echo "==> Creating virtualenv (.venv)"
"$PYTHON" -m venv .venv

echo "==> Installing dependencies"
./.venv/bin/python -m pip install --upgrade pip
./.venv/bin/python -m pip install -r helper/requirements.txt

echo
echo "Done."
if [ ! -f .env ]; then
  echo "Next: cp .env.example .env  and set GEMINI_API_KEY"
fi
echo "Verify:  ./.venv/bin/python helper/main.py model-info"
