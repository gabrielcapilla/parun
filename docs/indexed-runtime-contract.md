# Indexed Runtime Ownership Contract

This document is the Phase 1 ownership contract for the future indexed runtime.

## Build Facts

- Repository build config comes from [nim.cfg](/home/human/Git/Public/parun/nim.cfg).
- The repo explicitly enables `--threads:on`.
- The repo does not override `--mm`, so memory-manager behavior depends on the active Nim toolchain defaults for the command being run.
- Phase 1 diagnostics must always record `nim --version`, the exact build command, and whether the binary under test was built with `-d:release`.

## Hard Rules For Indexed Data

- Mapped package indexes are immutable storage, not heap-owned package models.
- The hot search path must operate on pointer plus length views, `openArray[char]`, or fixed-size integer IDs.
- The hot search path must not construct Nim `string` values just to compare names, prefixes, or posting-list candidates.
- Heap promotion from mapped data is allowed only at explicit cold boundaries and must be measurable.
- Any future `mmap` reader must make copy boundaries obvious in code review.
- Validation of `.prix` indexes must also stay file-backed. Reading the entire index into a heap `string` during startup validation is forbidden because it destroys the idle-memory contract.

## Cold Boundaries Where Copies Are Allowed

- Selected-row details formatting for the visible package.
- External command invocation that requires an owned `string`.
- Error reporting and status text shown to the user.
- Persisted diagnostic snapshots written to disk.

## Existing Copying Surfaces That Cannot Stay On The Future Hot Path

- [getName](/home/human/Git/Public/parun/src/core/state.nim#L83)
- [getVersion](/home/human/Git/Public/parun/src/core/state.nim#L87)
- [getRepo](/home/human/Git/Public/parun/src/core/state.nim#L91)
- [getPkgId](/home/human/Git/Public/parun/src/core/state.nim#L105)
- [renderDetails](/home/human/Git/Public/parun/src/ui/renderer.nim#L124) because it wraps and rewrites detail text into heap strings
- [MsgError handling](/home/human/Git/Public/parun/src/core/systems/update_system.nim#L205) because it builds display strings for the UI

## Existing Code Paths Already Aligned With The Future Direction

- [filterIndices](/home/human/Git/Public/parun/src/core/systems/search_system.nim#L4) reads package names from the arena through pointer plus length access rather than allocating names per candidate.
- [withBinaryCache](/home/human/Git/Public/parun/src/pkgs/cache.nim#L169) already demonstrates a memory-mapped, pointer-based iteration pattern suitable for immutable indexes.
- [validateSourceIndex](/home/human/Git/Public/parun/src/pkgs/indexes.nim) now validates directly over a mapped file instead of heap-loading the full artifact.
- [manager.nim](/home/human/Git/Public/parun/src/pkgs/manager.nim) now keeps the worker cold until details or diagnostics are actually requested.

## Phase 1 Diagnostics Contract

- `bash tools/measure_baseline.sh` is the release-build baseline harness.
- `bash tools/byte_accounting.sh` emits the current ownership report.
- `nimble verifyRuntime` is the regression gate for idle memory and visible source-switch latency.
- Both commands must write machine-readable artifacts under `tools/output/`.
- Any future architecture claim about memory reduction or zero visible latency must cite one of those artifacts or a newer compatible artifact.
