# Package

version       = "0.5.3"
author        = "Gabriel Capilla"
description   = "Terminal UI for pacman, AUR & nimble"
license       = "MIT"
srcDir        = "src"
bin           = @["parun"]

# Dependencies

requires "nim >= 2.2.6"

# Tasks

task release, "Build optimized release binary":
  exec "nimble build -d:release"

task measureBaseline, "Build release binary and run the scripted baseline harness":
  exec "bash tools/measure_baseline.sh"

task verifyRuntime, "Fail if indexed runtime budgets regress":
  exec "nimble build -d:release"
  exec "nim c -d:release --path:src -o:tools/.measure_baseline_bin tools/measure_baseline.nim"
  exec "tools/.measure_baseline_bin --binary=$PWD/parun --output=$PWD/tools/output/baseline.json --max-idle-rss-kb=12288 --max-idle-pss-kb=8192 --max-idle-private-dirty-kb=6144 --max-switch-visible-ms=25"

task byteAccounting, "Load package data and emit the byte-accounting report":
  exec "bash tools/byte_accounting.sh"

task buildIndexes, "Build deterministic immutable source indexes":
  exec "bash tools/build_indexes.sh"
