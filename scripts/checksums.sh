#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 <artifact> [artifact ...]" >&2
  exit 2
fi

for artifact in "$@"; do
  if [[ ! -f "$artifact" ]]; then
    echo "Missing artifact: $artifact" >&2
    exit 1
  fi
done

shasum -a 256 "$@"
