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

- `nimble buildIndexes`
- `bash tools/build_indexes.sh --output-dir="$HOME/.cache/parun/indexes"`

## Validation Commands

- `nimble measureBaseline`
- `nimble byteAccounting`
- `nimble verifyRuntime`

`verifyRuntime` is the enforcement gate. It currently fails when any of these budgets are exceeded on the measured release binary:

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

- `tools/output/baseline.json`
- `tools/output/byte_accounting.json`

Any future change that claims a memory or latency win must update one of these artifacts or provide a compatible successor artifact with the same procfs metrics.
