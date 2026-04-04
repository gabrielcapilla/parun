#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/tools/output"

mkdir -p "$OUT_DIR"
cd "$ROOT_DIR"

nimble build -d:release
nim c -d:release --path:src -o:tools/.measure_baseline_bin tools/measure_baseline.nim
tools/.measure_baseline_bin --binary="$ROOT_DIR/parun" --output="$OUT_DIR/baseline.json"
