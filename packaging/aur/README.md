# AUR Packaging Workflow

1. Create and push tag: `vX.Y.Z`.
2. Update `pkgver` and source URL in `PKGBUILD` and `.SRCINFO`.
3. Compute checksum for GitHub tag tarball and replace `REPLACE_WITH_TAG_TARBALL_SHA256`.
4. Validate locally:

```bash
cd packaging/aur
makepkg -sCf
```

5. Publish from a clean clone of the AUR git package repo.

Notes:
- `nimble release` is deterministic and portable by default.
- Do not inject `-march=native` or AVX-only flags in AUR packages.
