#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${1:-$ROOT_DIR/tools/output/indexes}"

if [[ "$OUT_DIR" == --output-dir=* ]]; then
  OUT_DIR="${OUT_DIR#--output-dir=}"
fi

mkdir -p "$OUT_DIR"
cd "$ROOT_DIR"

nim c -d:release --path:src -o:tools/.build_indexes_bin tools/build_indexes.nim
tools/.build_indexes_bin --output-dir="$OUT_DIR"
