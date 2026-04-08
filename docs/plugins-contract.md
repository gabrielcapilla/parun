# Plugins Contract

This document defines the extension contract for package adapters without implementing new distro adapters yet.

## Current Contract Files

- `src/plugins/contracts.nim`
- `src/plugins/registry.nim`

## Contract Model

- `PluginId`: stable adapter identity (`pacman`, `paru`, `yay`, `nimble`).
- `PluginContract`: command contract used by manager/worker orchestration.
- `PluginCapability`: explicit features advertised by each adapter.
- Compile-time guards validate every declared plugin contract during build.

## Runtime Selection

- `detectSystemPlugin()` picks the best available system adapter at startup (`paru` → `yay` → `pacman`).
- `pluginForSource(source, systemPlugin)` maps source selection to a concrete adapter.
- Runtime preflight enforces required capabilities before worker and transaction execution.

## Non-Goals In This Pass

- No Fedora/DNF adapter yet.
- No Debian/APT adapter yet.
- No changes to package indexing format or runtime search pipeline.

## Next Adapter Onboarding Checklist

1. Add `PluginId` and `PluginContract` entry in `contracts.nim`.
2. Add detection/selection rule in `registry.nim` if needed.
3. Add parser + details flow module(s) under `src/plugins/`.
4. Wire worker paths for load/search/details using current message protocol.
5. Validate with `nimble release` and runtime smoke checks (`aur/`, `nim/`, details panel, install/remove path).
