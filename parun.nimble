# Package

version = "0.7.0"
author = "Gabriel Capilla"
description = "Terminal UI for pacman, AUR & nimble"
license = "GNU AGPLv3"
srcDir = "src"
bin = @["parun"]

# Dependencies

requires "nim >= 2.2.0"

# Tasks

proc assertPortableIsa(binaryPath: string) =
  let notes = gorge("readelf -n " & binaryPath)
  for line in notes.splitLines:
    if "x86 ISA needed" in line:
      echo line

  if notes.contains("x86-64-v2") or notes.contains("x86-64-v3") or
      notes.contains("x86-64-v4"):
    quit("ERROR: " & binaryPath & " requires a non-baseline x86-64 ISA.", 1)

proc assertNoForbiddenX86Instructions(binaryPath: string) =
  let disassembly = gorge("objdump -d " & binaryPath)
  for token in ["%ymm", "%zmm", "\tv", "\tmulx", "\tpdep", "\tpext"]:
    if disassembly.contains(token):
      quit("ERROR: " & binaryPath & " contains non-baseline x86 instructions.", 1)

task native, "Build hyper-optimized local binary for this machine":
  mkDir "bin"
  exec "nim compile -d:release --nimcache:nimcache/release-native --passC:-march=native -o:parun src/parun.nim"

task baseline_x86_64_v3, "Build optimized GitHub Release binary for x86-64-v3 CPUs":
  mkDir "bin"
  exec "nim compile -d:release --nimcache:nimcache/release-v3 --passC:-march=x86-64-v3 -o:bin/parun-linux-x86_64-v3 src/parun.nim"

task baseline_x86_64, "Build portable GitHub Release binary for x86-64 baseline CPUs":
  mkDir "bin"
  exec "nim compile -d:release --nimcache:nimcache/release-generic --passC:-march=x86-64 --passC:-mtune=generic --passC:-mno-avx --passC:-mno-avx2 --passC:-mno-bmi --passC:-mno-bmi2 --passC:-mno-fma --passC:-mno-lzcnt --passC:-mno-popcnt --passC:-Wa,-mx86-used-note=no --passL:-march=x86-64 --passL:-mtune=generic --passL:-mno-avx --passL:-mno-avx2 --passL:-mno-bmi --passL:-mno-bmi2 --passL:-mno-fma --passL:-mno-lzcnt --passL:-mno-popcnt --passL:-Wa,-mx86-used-note=no -o:bin/parun-linux-x86_64 src/parun.nim"
  exec "objcopy --remove-section .note.gnu.property bin/parun-linux-x86_64"
  assertPortableIsa("bin/parun-linux-x86_64")
  assertNoForbiddenX86Instructions("bin/parun-linux-x86_64")
  echo "OK: bin/parun-linux-x86_64 has no non-baseline x86-64 ISA requirement."
