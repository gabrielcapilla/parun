import os

version = "0.8.0"
author = "Gabriel Capilla"
description = "Terminal UI for pacman, AUR & nimble"
license = "MIT"
srcDir = "src"
bin = @["parun"]

requires "nim >= 2.2.0"

proc assertPortableIsa(binaryPath: string) =
  let notes = gorge("readelf -n " & binaryPath)
  for line in notes.splitLines:
    if "x86 ISA needed" in line:
      echo line

  if notes.contains("x86-64-v2") or notes.contains("x86-64-v3") or
      notes.contains("x86-64-v4"):
    quit("ERROR: " & binaryPath & " requires a non-baseline x86-64 ISA.", 1)

proc assertNoForbiddenX86Instructions(binaryPath: string) =
  let forbidden = gorge(
    "objdump -d " & binaryPath &
      " | grep -E '%ymm|%zmm|[[:space:]]v|[[:space:]]mulx|[[:space:]]pdep|[[:space:]]pext' || true"
  )
  if forbidden.len > 0:
    quit("ERROR: " & binaryPath & " contains non-baseline x86 instructions.", 1)

task native, "Build hyper-optimized local binary for this machine":
  exec "nim compile -d:release --nimcache:nimcache/release-native --mm:arc --passC:-march=native -o:parun src/parun.nim"

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

const TestPrograms = [
  "tests/test_detail_cache.nim", "tests/test_detail_generation.nim",
  "tests/test_headless_detail.nim", "tests/test_nimble_info.nim",
  "tests/test_navigation.nim", "tests/test_pacman_local_db.nim",
  "tests/test_source_index.nim", "tests/test_transaction_command.nim",
  "tests/test_wrap_text.nim", "tests/test_worker_exec.nim",
]

task format_check, "Check maintained Nim formatting":
  exec "nph --check $(rg --files --no-messages src tests tools benchmarks -g '*.nim' | sort) parun.nimble"

task test, "Compile and run every standalone test program":
  let testDir = "/tmp/parun-tests"
  mkDir testDir
  for testProgram in TestPrograms:
    let stem = splitFile(testProgram).name
    let output = testDir / stem
    exec "nim c --path:src --mm:arc -o:" & output & " " & testProgram
    exec output

task docs, "Generate Nim API documentation":
  let output = "/tmp/parun-docs"
  mkDir output
  exec "nim doc --project --index:on --outdir:" & output & " src/parun.nim"

task measure_sweep, "Compile the repeated RSS/PSS measurement runner":
  exec "nim c --path:src --mm:arc -o:/tmp/parun-measure-sweep tools/measure_sweep.nim"

task headless_smoke, "Build and run the public headless CLI smoke test":
  let output = "/tmp/parun-headless-smoke"
  mkDir output
  let application = output / "parun"
  let smoke = output / "headless_cli_smoke"
  exec "nim c --path:src --mm:arc -o:" & application & " src/parun.nim"
  exec "nim c --path:src --mm:arc -o:" & smoke & " tools/headless_cli_smoke.nim"
  exec smoke & " --binary=" & application

task verify, "Run formatting, package, tests, and documentation gates":
  exec "git diff --check"
  exec "nimble format_check"
  exec "nimble check"
  exec "nimble test"
  exec "nimble headless_smoke"
  exec "nimble measure_sweep"
  exec "nimble docs"

task release_verify, "Run all verification gates and release target builds":
  exec "nimble verify"
  exec "nimble native"
  exec "nimble baseline_x86_64"
  exec "nimble baseline_x86_64_v3"
