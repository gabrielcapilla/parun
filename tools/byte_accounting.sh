#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/tools/output"

mkdir -p "$OUT_DIR"
cd "$ROOT_DIR"

nim c -d:release --path:src -o:tools/.byte_accounting_bin tools/byte_accounting.nim
tools/.byte_accounting_bin --output="$OUT_DIR/byte_accounting.json"
