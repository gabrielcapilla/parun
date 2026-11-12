# Architecture

Parun is a Linux terminal application organized around five runtime domains: catalog state, immutable indexes, source backends, terminal UI, and application orchestration, plus platform and diagnostics support modules. The `src/parun.nim` entrypoint composes those domains; it does not contain the package-source parsers, index codec, or renderer implementations.

## Source tree

| Directory         | Responsibility                                                                                                      | Main boundary                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `src/app`         | Input interpretation, navigation, message reduction, and compile-time version extraction.                           | Converts terminal or worker events into catalog state changes.                   |
| `src/catalog`     | Source-slot state, search/filtering, selection identity, detail cache, and view state.                               | Owns mutable UI-facing state and filtered index identities.                       |
| `src/index`       | `.prix` schema, encoding, building, structural validation, eager/lazy proofs, and mmap-backed accessors.            | Supplies immutable source-index views to catalog and refresh code.               |
| `src/sources`     | Pacman/AUR/Nimble metadata, source contracts, runtime refresh, worker protocol, caches, and blocking operations.    | Keeps external commands, network I/O, and cache persistence outside the UI loop. |
| `src/ui`          | Raw terminal input, terminal lifecycle, layout, row/details/status rendering, and frame assembly.                   | Reads terminal events and renders `AppState` without owning source data.         |
| `src/platform`    | Operating-system probes used by runtime infrastructure.                                                             | Isolates Linux `statx` and procfs details from domain code.                      |
| `src/diagnostics` | Worker memory-report structures, owned-capacity accounting, opt-in details lifecycle tracing, and terminal-free headless probes. | Provides diagnostics without becoming a general-purpose utility layer.           |

`catalog/state.nim` is the state composition boundary: it constructs `AppState` and brings its tightly coupled state helpers into one domain import. `index/indexes.nim` is the corresponding source-index domain surface for the single v7 schema, codec, builder, validator, runtime reader, and lazy proof modules. The lazy proof module is a validation strategy, not a second format reader; there are no v5 or v6 runtime readers. Leaf modules can still import the specific implementation module when they do not need the aggregate surface.

## Dependency direction

The maintained imports establish these boundaries:

```text
platform ───────────────┐
diagnostics ────────────┤
index core/codec ───────┤
          │             │
index builder/validator/runtime/lazy
          │             │
catalog model/search/selection/state/layout
          │             │
sources metadata/backends/worker/refresh
          │             │
app input/update/navigation
          │             │
ui keyboard/terminal/layout/renderer/tui
          │             │
        src/parun.nim
```

The diagram is a dependency guide rather than a claim that every module imports every layer. In particular:

- index modules depend on the standard library and their own index primitives;
- catalog code consumes index views and does not perform external I/O;
- sources depend on the catalog message/data types but do not import UI renderers;
- UI modules consume catalog/index state and do not import source backends;
- the executable is the composition root for terminal, worker, catalog, and refresh behavior.

There are no maintained imports through the removed `core`, `plugins`, `storage`, or generic `utils` source trees. The only aggregate imports are domain-specific (`catalog/state` and `index/indexes`) and each names the modules it composes explicitly.

## Startup and event flow

1. `src/parun.nim` parses CLI options and handles the non-interactive headless and internal diagnostic commands before opening the terminal.
2. Interactive startup initializes the terminal and package-manager bridge, constructs `AppState` with `catalog/state.newState`, and prepares the enabled immutable source indexes.
3. The selector watches standard input and the resize pipe. Keyboard bytes are decoded by `ui/keyboard`, and resize events are forwarded by `ui/terminal`.
4. `app/input` and `app/input_handler` update query, cursor, source, and selection intent. Search and source transitions remain in the catalog domain.
5. `sources/package_manager` sends requests through the worker channel. The worker owns blocking process, filesystem, metadata, and network work and emits compact `Msg` values. Nimble details are staged: the refresh path embeds the registry summary in `nimble.prix`, the UI displays it immediately, and the worker asynchronously enriches it from the repository `.nimble` manifest when `Author` or `Depends On` is needed. Successful manifest results use the bounded `sources/nimble_detail_cache` sidecar, so a later process can serve the complete result without another repository fetch. Nimble manifest downloads use short-lived argv-based `curl` processes with bounded output and a whole-request deadline, so TLS state is not retained in the worker. The same worker and formatter are used by `diagnostics/headless` for one-shot detail checks.
6. `app/update` reduces messages into `AppState`; `ui/tui` and `ui/renderer` turn the state into one terminal frame.
7. Shutdown uses the entrypoint's cleanup block to close the selector, mapped indexes, terminal mode, and worker.

## Immutable source indexes

Source catalogs are persisted as sectioned `.prix` files. The schema is owned by `index/source_index_core`; v7 is the only supported format and older format versions are rejected. Builders write hot name/search sections, cold version/repository sections, installed flags, per-package Nimble URL sections, optional registry detail sections, and first-byte bucket sections. The validator checks file bounds, section presence and sizes, packed maps, bucket IDs, optional detail maps, and compressed-blob invariants before a runtime view is mapped.

The v7 runtime reader exposes pointer/length accessors over the mapped file rather than reconstructing the complete package corpus. Its lazy proof mode defers the bucket, version, repository, URL, and registry-detail proofs until their corresponding access path requires them; each proof is idempotent and reports the same verdict as the eager validator. This is one v7 reader with two proof timings, not compatibility support for multiple persisted formats. `catalog/search` requests the bucket proof before using a bucket range, and the Nimble details path requests the detail proof before reading a local payload.

## Memory ownership and cold data

The immutable index reader separates hot name/search sections from cold version, repository, URL, and registry-detail sections. Search results can use an identity view for an unfiltered catalog instead of materializing every package index. Detail text is bounded by `DetailsCacheLimit` (64 entries), `DetailsCacheByteBudget` (262,144 bytes), and `MaxDetailPayloadBytes` (16 KiB); the UI-side and worker-side caches grow their encoded arenas on demand from a 1 KiB initial allocation instead of reserving the full budget for the first response. Rendered strings use normal Nim strings and are retained only where the current frame or wrapped details need them.

`diagnostics/detail_trace` is disabled unless `PARUN_DETAIL_TRACE` names a file. When enabled, it records process residency, cache ownership, wrapped-line capacity, cold decode-ring ownership, render-buffer capacity, request state, enrichment state, and reveal state at details-view transitions. The trace is intended for measurement and does not add file or procfs work to normal interactive execution.

These are source-level budgets and capacities, not a claim about total process RSS. Measure process memory with the repository's benchmark tools and the runtime diagnostics before making a performance conclusion.

The interactive details transition has two different memory effects. The AUR `.prix` mapping becomes more resident as the selected package's index fields are faulted in, so those file-backed pages appear in RSS/PSS even though they are not copied into the detail cache. Non-Nimble details do not prove or copy the optional URL section because their worker paths do not consume `pkgUrl`; Nimble proves and reads the optional registry-detail section first, renders that summary, and then uses the URL for one asynchronous manifest enrichment request. The first remote worker request also creates a Nim thread whose anonymous virtual mapping accounts for the large `VmSize` increase; only a small portion becomes resident. A warm Nimble sidecar hit avoids the repository network request but still uses the existing worker message path. The detail payload, sidecar record, and both bounded in-memory arenas remain size-limited. See `docs/development.md` for the reproducible PTY measurement and mapping-level result.

## Source contracts

`sources/source_contracts` defines the capabilities and command templates for Pacman, Paru, Yay, and Nimble. `source_registry` chooses `paru`, then `yay`, then `pacman` when selecting a system provider. The worker uses the contract for command execution while source-specific modules parse package metadata and details.
