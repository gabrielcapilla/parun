# Indexed Runtime Operations

This document records the operational contract for Parun's low-RAM indexed runtime.

## Runtime Guarantees

- Search and source switching operate over immutable `.prix` indexes mapped into the process address space.
- `aur/`, `nim/`, and default local mode do not trigger parsing, decompression, or network work in the interactive path.
- The background worker stays cold until details or diagnostics are explicitly requested.

## Index Lifecycle

- Runtime indexes live under `~/.cache/parun/indexes/`.
- The runtime validates existing indexes before mapping them.
- If an index is missing or invalid, Parun rebuilds indexes out of process by invoking the builder helper, then retries validation and mapping.

## Rebuild Commands

- `parun` rebuilds missing/invalid indexes automatically at runtime.
- `nimble release` validates the public deterministic build contract.

## Validation Commands

- Runtime budgets are validated in maintainer-private harnesses that are intentionally kept out of the public repository.
- Public release gate is successful `nimble release` plus interactive smoke checks on source switching and details rendering.
- Target budgets for release verification:

- idle `RSS > 12288 KiB`
- idle `PSS > 8192 KiB`
- idle `Private_Dirty > 6144 KiB`
- visible `aur/` or `nim/` switch latency `> 25 ms`

## Copy Boundaries

- Hot-path comparisons must stay on mapped bytes and integer IDs.
- Heap strings are allowed only for:
  - selected-row detail requests
  - package transaction command construction
  - user-visible status and error text
  - serialized diagnostics

## Measurement Artifacts

- Public repository keeps contracts and runtime code only.
- Raw benchmark and accounting artifacts remain private maintainer data and are not committed.
