# Version 0.8.0 repository review

This review compares the working tree with public `main` at `9417b3f` (the local `v0.7.1` tag plus two release-infrastructure commits). The 0.8.0 implementation is uncommitted, so ordinary `git diff` statistics omit its untracked source files. Performance observations below describe implementation changes, not measured improvements over the public version.

## Significant changes

1. **Domain organization:** `src/core`, `src/plugins`, `src/storage`, and `src/utils` have been reorganized into `app`, `catalog`, `sources`, `index`, `platform`, and `diagnostics`. The entry point composes the application; see `architecture.md` for ownership and dependencies.
2. **Indexes and search:** the v7 `.prix` format uses memory-mapped views, separates hot and cold data, and supports deferred validation of sections. Search can use bucketed lookups and an identity view instead of materializing an unfiltered result list. Older index formats must be regenerated.
3. **Details and memory:** UI and worker detail caches have bounded entry and byte budgets and allocate their arenas on demand. Nimble details first use indexed registry data, then asynchronously enrich it from a manifest and cache complete results in a persistent sidecar.
4. **Worker resilience:** external process execution has bounded output and deadlines; request generations prevent stale detail responses from replacing current state. Manifest fetches use short-lived `curl` processes, and the compiler configuration no longer links OpenSSL directly.
5. **Diagnostics and verification:** headless search and detail commands emit JSON without initializing the terminal. New tests cover index corruption, cache behavior, stale requests, headless details, and worker limits; Nimble tasks run formatting, tests, smoke checks, and documentation generation.
6. **Build configuration:** the local native release uses ARC. Portable and x86-64-v3 release targets remain available, with an instruction check for the baseline target.

## Cleanup and release considerations

- Compiled test executables in `tests/` are reproducible build artifacts; the six present during this review were removed and matching binaries are now ignored. Source tests remain.
- The old source trees and AUR packaging files are already deleted in the working tree. Their replacements and all other uncommitted work must be included intentionally when preparing a commit.
- `tools/` and `benchmarks/` are generally ignored by the current repository policy. The two programs required by `nimble verify` are tracked explicitly; other developer probes referenced in `development.md` remain local. Measurement output under `tools/output/` is evidence and was preserved.
- The package manifest and `LICENSE` now both specify MIT, following the owner’s relicensing instruction.
- Public `main` adds `.github/workflows/release.yml` and `ci/manifest.sh`, and removes the obsolete `install.sh`; these changes are incorporated in this checkout. The release workflow builds both x86-64 targets and publishes a verified manifest when a matching version tag is pushed.
- Cached compiler output under `nimcache/` is regenerable but was retained to avoid discarding local build state. No source module was removed solely because its use could not be proven from a local search.
