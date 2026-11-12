import std/[os, tables, unittest]
import ../src/sources/pacman

suite "pacman local database parsing":
  test "extracts package names directly from query output":
    let installed = parseInstalledPackages("alpha 1.0\n  beta 2.0\n\nno-version\n")
    check installed.len == 3
    check installed.hasKey("alpha")
    check installed.hasKey("beta")
    check installed.hasKey("no-version")

  test "reads installed package names from desc files":
    let root = getTempDir() / "parun-pacman-local-test"
    removeDir(root)
    createDir(root / "alpha-1.0-1")
    createDir(root / "lib-with-hyphen-2.3-4")
    writeFile(root / "alpha-1.0-1" / "desc", "%NAME%\nalpha\n\n%VERSION%\n1.0-1\n")
    writeFile(
      root / "lib-with-hyphen-2.3-4" / "desc",
      "%VERSION%\n2.3-4\n\n%NAME%\nlib-with-hyphen\n",
    )

    let installed = parseInstalledPackagesFromLocalDb(root)
    check len(installed) == 2
    check installed.hasKey("alpha")
    check installed.hasKey("lib-with-hyphen")

    removeDir(root)

  test "skips malformed entries without guessing from directory names":
    let root = getTempDir() / "parun-pacman-local-malformed-test"
    removeDir(root)
    createDir(root / "pkg-name-1.0-1")
    writeFile(root / "pkg-name-1.0-1" / "desc", "%VERSION%\n1.0-1\n")

    let installed = parseInstalledPackagesFromLocalDb(root)
    check len(installed) == 0

    removeDir(root)
