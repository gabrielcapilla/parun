# Source Architecture Contract

This project uses a Kepano-style source layout: low depth, clear names, and composable modules.

## Directory Depth Rule

- `src/` can contain module groups such as `core`, `ui`, `plugins`, `storage`, `utils`.
- One grouping level is allowed (`src/<group>/file.nim`).
- Deeper nesting is not allowed (`src/<group>/<subgroup>/file.nim`).

## Runtime Groups

- `core`: state model, search/filter systems, input/update orchestration.
- `ui`: terminal rendering and interaction surface (engine-facing layer).
- `plugins`: package-source backends and worker pipeline.
- `storage`: immutable index formats, readers, builders, and refresh mechanics.
- `utils`: shared low-level utilities and metrics helpers.

## Naming Rules

- Use explicit names over generic names:
  - `worker_details.nim` instead of mixed logic in `worker.nim`.
  - `search_system.nim` instead of ambiguous `search.nim`.
- Keep nouns for data modules and verbs/systems for behavior modules.
- Avoid overloaded names that mix data model + I/O + rendering in one file.

## Size and Responsibility

- Target focused files with one main responsibility.
- Large files are allowed only for performance-critical data pipelines that would regress from fragmentation.
- Split orchestration from low-level primitives:
  - command execution and retries in one module,
  - detail resolution pipeline in another,
  - dispatcher loop in another.

## Plugin Extension Direction

- New distro support should be added under `src/plugins/` with the same worker protocol.
- Source-specific package parsing and metadata fetching stay plugin-local.
- Core/UI should depend on plugin contracts, not plugin internals.
- Keep a stable contract surface:
  - `contracts.nim` for static adapter capability/schema.
  - `registry.nim` for runtime adapter selection.
  - contract validation runs at compile time, capability preflight runs at runtime.
