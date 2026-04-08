# Package

version       = "0.6.0"
author        = "Gabriel Capilla"
description   = "Terminal UI for pacman, AUR & nimble"
license       = "GNU AGPLv3"
srcDir        = "src"
bin           = @["parun"]

# Dependencies

requires "nim >= 2.2.6"

# Tasks

task release, "Build deterministic release binary for public distribution":
  exec "nimble build -d:release"

task releaseNative, "Build host-optimized binary for local use only":
  exec "nimble build -d:release --passC:-march=native"

task releasePortable, "Build release binary and fail if ISA requires x86-64-v3/v4":
  exec "nimble build -d:release"
  exec """bash -lc 'set -euo pipefail; props=$(readelf -n ./parun 2>/dev/null | grep -F "x86 ISA needed" || true); if [ -n "$props" ]; then echo "$props"; fi; if echo "$props" | grep -Eq "x86-64-v3|x86-64-v4"; then echo "ERROR: parun binary requires x86-64-v3/v4 and is not portable to older x86_64 CPUs."; exit 1; fi; echo "OK: no x86-64-v3/v4 requirement detected." '"""
