# Changelog

## 0.6.0 - 2026-04-08

### Added
- New source-index runtime pipeline (`src/storage/source_index_*`) with compressed cold payload support.
- Plugin-oriented package backend contract under `src/plugins/`.
- Structural architecture docs for `src/` and plugin extension contract.
- AUR packaging scaffolding under `packaging/aur/`.

### Changed
- Public release task is now deterministic and CPU-portable (`nimble release`).
- Added explicit local-only host optimization task (`nimble releaseNative`).
- Runtime and plugin docs aligned to public repository contract.

### Removed
- Legacy `src/pkgs/*` backend layout.
- Legacy nested `src/core/systems/*` paths.
- Public tracking of private `tools/` scripts/artifacts.
