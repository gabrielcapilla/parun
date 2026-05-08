# Kernel Sympathy Roadmap

This roadmap keeps Linux-specific optimization behind empirical gates. Each
step must preserve existing behavior, compile cleanly, and show benchmark data
before it is considered complete.

## Gate Commands

Run after every implementation step:

```bash
nim r --hints:off tests/test_nimble_info.nim
nim r --hints:off tests/test_wrap_text.nim
nimble build --hints:off
nimble baseline_x86_64
```

## Step 1: Advise Mapped `.prix` Indexes

Target: `src/storage/source_index_runtime.nim`.

Status: rejected after benchmark.

Result:

- Candidate patch called Linux `madvise` after mapping a validated `.prix`.
- Warm-index microbenchmark regressed slightly: 322,374 ns/open baseline vs
  328,237 ns/open with advice on `merged.system-aur-nimble.prix`.
- Minor faults were effectively unchanged: 99,011 baseline vs 99,009 with
  advice.
- Patch was removed. Do not reintroduce without a cold-cache benchmark that
  shows a net win.

## Step 2: Direct Installed Pacman State

Target: installed package map currently sourced through `pacman -Q`.

Status: implemented.

Result:

- Parses `/var/lib/pacman/local/<pkg-version>/desc` directly.
- Keeps `pacman -Q` fallback when local DB parsing returns no entries.
- Installed package parity on this machine: `pacman -Q` count 2269, local
  `desc` count 2269, missing 0, extra 0.
- System index refresh benchmark, seven rounds:
  - Baseline median: 322.180 ms.
  - Direct local DB median: 282.791 ms.
  - Median gain: 39.389 ms, 12.23%.

## Step 3: pidfd Transaction Supervision

Target: external install/remove process tracking.

Status: implemented.

Result:

- Transaction commands now use `startProcess` with argv instead of shell
  command strings.
- Linux path opens a pidfd for the child process and waits for that exact fd to
  become readable before reaping through Nim's process handle.
- Non-Linux or unsupported-kernel path falls back to the normal process wait.
- pidfd smoke test on this kernel returned fd `3`.
- Added tests for pacman/nimble transaction argv construction and shell
  metacharacter rejection.

## Step 4: Pacman Local DB Scan Tightening

Target: `src/plugins/pacman.nim`.

Status: implemented.

Result:

- Added `benchmarks/bench_pacman_local_db.nim` to separate directory iteration,
  `desc` discovery, direct local DB parsing, and `pacman -Q` process cost.
- `getdents64` gate did not pass: directory iteration averaged about 4.9 ms
  while full local DB parsing averaged about 19.9 ms on this machine, so
  replacing `walkDir` would not attack the dominant cost.
- Removed one avoidable `stat` per installed package by opening `desc`
  directly and relying on the existing unreadable-entry fallback path.
- Removed per-line `strip()` allocation from pacman `desc` parsing. Pacman
  local DB fields are line-oriented; malformed/unreadable entries are still
  skipped.
- Post-change repeated parse averages: 18.266 ms, 17.525 ms, 17.889 ms over
  40 iterations. Best observed gain against the initial run: 2.388 ms,
  about 12.0%.

## Step 5: statx Installed-State Freshness Checks

Target: `src/storage/index_builder.nim`.

Status: implemented.

Result:

- Added a Linux `statx` wrapper for mtime-only metadata reads with
  `AT_STATX_DONT_SYNC`, `AT_NO_AUTOMOUNT`, and a stdlib fallback.
- Applied it only to installed-state freshness checks, where parun compares
  package-manager state mtimes against `.prix` index mtimes before deciding
  whether to rebuild indexes.
- Added `benchmarks/bench_statx_mtime.nim` to compare stdlib
  `getLastModificationTime` scanning with `statx` scanning on the same
  directory.
- Parity check on `/var/lib/pacman/local`: stdlib and `statx` returned the same
  newest mtime (`1778235558862441391` ns).
- Final benchmark over 60 iterations:
  - stdlib newest-mtime scan: 6.412 ms average.
  - `statx` newest-mtime scan: 6.065 ms average.
  - Gain: 0.347 ms, about 5.4%.

## Deferred

- `getdents64`: rejected for now. Local benchmark showed directory iteration is
  a minority of installed-state parse time after direct pacman DB parsing.
- `io_uring`: defer; mmap plus `madvise` is lower risk and fits current design.
- `eventfd`: defer until channel wakeups are measured as a bottleneck.
- `memfd_create`: defer; parun benefits from durable metadata/index caches.
- `process_vm_readv`: reject for now; too brittle and unnecessary.
