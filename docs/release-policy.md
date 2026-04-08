# Release and Version Policy

## Public Build Contract

- Public builds must be deterministic and portable.
- `nimble release` is the official release command for public artifacts.
- Public builds must not inject host-specific flags such as `-march=native`.
- AVX2 builds are optional local/profile builds and must never replace the portable release artifact.

## SIMD Compatibility Policy

- Default compile path remains CPU-safe for broad x86_64 compatibility.
- AVX2 code path is enabled only when explicitly requested (`-d:avx2` plus matching compiler flags).
- For published binaries, keep one portable baseline asset first.
- Optional extra assets can be shipped as explicit variants, for example:
  - `parun-linux-x86_64-generic`
  - `parun-linux-x86_64-avx2`

## Versioning

- Use SemVer tags: `vMAJOR.MINOR.PATCH`.
- `parun.nimble` version must match the release tag.
- Each release must include changelog notes and AUR metadata refresh.

## Release Order

1. Update `parun.nimble` version.
2. Run `nimble release`.
3. Validate runtime smoke checks (`aur/`, `nim/`, details panel).
4. Tag and push: `vX.Y.Z`.
5. Update `packaging/aur/PKGBUILD` and `.SRCINFO` with matching `pkgver` and checksum.
6. Publish release notes.
