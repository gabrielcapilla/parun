import std/[os, unittest]

import ../src/diagnostics/headless
import ./helpers

suite "headless detail diagnostics":
  test "resolves a detail without initializing the terminal":
    let root = getTempDir() / ("parun-headless-detail-" & $getCurrentProcessId())
    let fixtureDir = root / "indexes"
    let stubDir = root / "bin"
    let cacheDir = root / "cache"
    removeTree(root)
    createDir(stubDir)
    discard makeNimbleFixture(fixtureDir)
    let curlStub = stubDir / "curl"
    writeFile(
      curlStub,
      "#!/bin/sh\n" &
        "printf '%s\\n' 'version = \"1.2.3\"' 'author = \"Fixture Author\"' 'requires \"nim >= 2.0.0\"'\n",
    )
    setFilePermissions(curlStub, {fpUserRead, fpUserExec})
    let oldPath = getEnv("PATH", "")
    let oldCache = getEnv("PARUN_CACHE_DIR", "")
    putEnv("PATH", stubDir & PathSep & oldPath)
    putEnv("PARUN_CACHE_DIR", cacheDir)
    defer:
      if oldPath.len > 0:
        putEnv("PATH", oldPath)
      else:
        delEnv("PATH")
      if oldCache.len > 0:
        putEnv("PARUN_CACHE_DIR", oldCache)
      else:
        delEnv("PARUN_CACHE_DIR")
      removeTree(root)

    check runHeadlessDetails(
      HeadlessDetailRequest(
        selector: "nimble/nph", indexDir: fixtureDir, timeoutMs: 5_000
      )
    ) == 0

  test "missing headless detail package fails":
    let root = getTempDir() / ("parun-headless-missing-" & $getCurrentProcessId())
    defer:
      removeTree(root)
    let fixtureDir = root / "indexes"
    discard makeNimbleFixture(fixtureDir)
    check runHeadlessDetails(
      HeadlessDetailRequest(
        selector: "nimble/missing", indexDir: fixtureDir, timeoutMs: 100
      )
    ) == 1
