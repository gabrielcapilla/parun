# Indexed Source Layout

This is the Phase 2 binary contract for offline-built, immutable source indexes.

## Goals

- Keep package corpora out of mutable heap state.
- Split hot search data from colder display data.
- Make every section memory-mappable and directly addressable.
- Keep the file deterministic for the same input snapshot.

## Endianness

- All integer fields are little-endian.

## File Header

Bytes 0-31:

- `magic[4]`: `PRIX`
- `version[u32]`: `3`
- `source_kind[u32]`: `0=system`, `1=aur`, `2=nimble`
- `package_count[u32]`
- `repo_count[u32]`
- `section_count[u32]`
- `header_bytes[u32]`: `32`
- `reserved[u32]`: `0`

## Section Directory

Immediately after the 32-byte header comes a fixed-width section directory.

Each directory entry is 32 bytes:

- `name[16]`: ASCII section name, zero-padded
- `offset[u64]`: absolute file offset
- `size[u64]`: section size in bytes

## Current Sections

Hot package-name path:

- `name_off`: `package_count` entries of `u32`
- `name_len`: `package_count` entries of `u16`
- `name_blob`: concatenated package names
- `lower_off`: `package_count` entries of `u32`
- `lower_len`: `package_count` entries of `u16`
- `lower_blob`: concatenated lowercase package names
- `repo_idx`: `package_count` entries of `u16`
- `flags`: `package_count` entries of `u8`
- `bucket_off`: `256` entries of `u32`
- `bucket_len`: `256` entries of `u32`
- `bucket_ids`: concatenated `u32` package IDs grouped by first lowercase byte

Cold display path:

- `ver_off`: `package_count` entries of `u32`
- `ver_len`: `package_count` entries of `u16`
- `ver_blob`: concatenated version strings
- `repo_off`: `repo_count` entries of `u32`
- `repo_len`: `repo_count` entries of `u16`
- `repo_blob`: concatenated repository names

## Determinism Rules

- Package order is preserved from the input snapshot.
- Repo indices are assigned in first-seen order.
- Lowercase names are derived with `toLowerAscii`.
- Section order is fixed and never data-dependent.

## Validation Rules

- The file must start with `PRIX`.
- The version must be exactly `3`.
- `header_bytes` must be exactly `32`.
- Every section range must stay within file bounds.
- `source_kind` must map to a known source enum.

## Why This Layout

- `name_*`, `lower_*`, `repo_idx`, `flags`, and `bucket_*` are the minimum hot search footprint.
- Versions and repo text stay separate so ordinary query filtering does not need to touch them.
- The layout can be memory-mapped without constructing `seq[string]` or `PackageDB`-style mutable corpora.

## Hot Narrowing Contract

- `bucket_off`, `bucket_len`, and `bucket_ids` form the current first-byte candidate directory.
- The runtime uses the first lowercase byte of the first token to narrow candidates before SIMD scoring.
- Package order in the main corpus is preserved; the bucket directory is auxiliary and deterministic.
- Optional detail-offset sections are still reserved for future cold-metadata work if the current worker-backed details path needs to be retired.
