import std/[os, strutils, unittest]

import ../src/sources/nimble
import ../src/sources/metadata_cache
import ../src/sources/nimble_detail_cache
import ../src/app/update
import ../src/catalog/model
import ../src/catalog/state
import ../src/ui/renderer

proc asString(value: openArray[char]): string =
  result = newString(value.len)
  for i in 0 ..< value.len:
    result[i] = value[i]

suite "nimble details panel":
  test "repository nimble file produces standardized package details":
    let raw = """
version     = "0.1.0"
author      = "Name Author"
description = "Some description"
license     = "MIT"
requires "nim >= 2.0.0", "pkg >= 1.0.0"
"""
    let info = parseNimbleInfo(
      raw,
      "package_name",
      "https://github.com/user/repository.git/",
      @["unused", "tags"],
    )

    check "Repository      : nimble" in info
    check "Name            : package_name" in info
    check "Version         : 0.1.0" in info
    check "Description     : Some description" in info
    check "URL             : https://github.com/user/repository" in info
    check "Licenses        : MIT" in info
    check "Author          : Name Author" in info
    check "Depends On      : nim >= 2.0.0, pkg >= 1.0.0" in info
    check "Tags" notin info
    check "Info from local nimble search cache" notin info

  test "nimlsp manifest shape extracts all standard detail fields":
    let raw = """
# Package

version       = "0.4.7"
author        = "PMunch"
description   = "Nim Language Server Protocol - nimlsp implements the Language Server Protocol"
license       = "MIT"
srcDir        = "src"
bin           = @["nimlsp", "nimlsp_debug"]

# Dependencies

requires "nim >= 1.0.0"
requires "jsonschema >= 0.2.1"
requires "asynctools >= 0.1.1"
"""
    let info = parseNimbleInfo(raw, "nimlsp", "https://github.com/PMunch/nimlsp", "")

    check "Repository      : nimble" in info
    check "Name            : nimlsp" in info
    check "Version         : 0.4.7" in info
    check "Description     : Nim Language Server Protocol - nimlsp implements the Language Server Protocol" in
      info
    check "URL             : https://github.com/PMunch/nimlsp" in info
    check "Licenses        : MIT" in info
    check "Author          : PMunch" in info
    check "Depends On      : nim >= 1.0.0, jsonschema >= 0.2.1, asynctools >= 0.1.1" in
      info

  test "github raw manifest candidates prefer refs heads branch path":
    let candidates =
      getRawNimbleFileCandidates("https://github.com/PMunch/nimlsp", "nimlsp")

    check candidates.len >= 2
    check candidates[0] ==
      "https://raw.githubusercontent.com/PMunch/nimlsp/refs/heads/master/nimlsp.nimble"
    check "https://raw.githubusercontent.com/PMunch/nimlsp/master/nimlsp.nimble" in
      candidates

  test "fallback search output stays partial":
    let raw = """
package_name:
  url:         https://github.com/user/repository (git)
  tags:        some, tags, foo, bar
  description: Some description
  license:     MIT
  version:     9.9.9
  author:      Cache Author
"""
    let info = formatFallbackInfo(raw)

    check "Repository      : nimble" in info
    check "Name            : package_name" in info
    check "Description     : Some description" in info
    check "URL             : https://github.com/user/repository" in info
    check "Licenses        : MIT" in info
    check "Version" notin info
    check "Author" notin info
    check "Depends On" notin info
    check "Tags" notin info
    check "Info from local nimble search cache" notin info

  test "registry fields are streamed without a repository fetch":
    let path =
      getTempDir() / ("parun-nimble-registry-" & $getCurrentProcessId() & ".json")
    defer:
      if fileExists(path):
        removeFile(path)
    writeFile(
      path,
      """[
  {"name":"nph","url":"https://github.com/PMunch/nph","description":"Nim package formatter","license":"MIT","web":"https://example.invalid/nph","tags":["formatter"]},
  {"name":"gitonly","url":"https://github.com/example/gitonly","tags":[]}
]""",
    )

    var rowCount = 0
    check streamParseNimbleRegistryZeroAlloc(
      path,
      proc(
          name, version, url, description, license, web: openArray[char]
      ) {.closure, gcsafe.} =
        inc rowCount
        if rowCount == 1:
          doAssert asString(description) == "Nim package formatter"
          doAssert asString(license) == "MIT"
          doAssert asString(url) == "https://github.com/PMunch/nph"
        else:
          doAssert asString(version) == "git"
      ,
    )
    check rowCount == 2

  test "complete manifest details use a bounded persistent sidecar":
    let cacheDir =
      getTempDir() / ("parun-nimble-detail-cache-" & $getCurrentProcessId())
    if dirExists(cacheDir):
      removeDir(cacheDir)
    let oldCacheDir = getEnv("PARUN_CACHE_DIR", "")
    putEnv("PARUN_CACHE_DIR", cacheDir)
    defer:
      if oldCacheDir.len > 0:
        putEnv("PARUN_CACHE_DIR", oldCacheDir)
      else:
        delEnv("PARUN_CACHE_DIR")
      let detailDir = cacheDir / "nimble-details"
      if dirExists(detailDir):
        for kind, path in walkDir(detailDir):
          if kind == pcFile:
            removeFile(path)
        removeDir(detailDir)
      if dirExists(cacheDir):
        removeDir(cacheDir)

    let full =
      "Repository     : nimble\nAuthor         : Test Author\nDepends On     : nim >= 2.0.0\n"
    check writeNimbleDetail(
      "test-package", "https://github.com/example/test-package.git", full
    )
    var loaded = ""
    check loadNimbleDetail(
      "test-package", "https://github.com/example/test-package", loaded
    )
    check loaded == full

  test "fallback details do not replace a registry summary":
    var state = newState(SlotNimble, false, {SlotNimble}, true)
    var summary = Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: 0,
      pkgSlot: SlotNimble,
      quality: DetailSummary,
      content: "Name           : test-package\nAuthor         : Registry\n",
    )
    update(state, summary, 10)
    state.lastDetailIdx = 0
    state.wrappedDetails = @["stale registry wrapping"]

    let manifestContent =
      "Name           : test-package\nAuthor         : Full Manifest\nDepends On     : nim >= 2.0.0\n"
    var manifest = Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: 0,
      pkgSlot: SlotNimble,
      quality: DetailManifest,
      content: manifestContent,
    )
    update(state, manifest, 10)
    check detailCacheGet(state.detailsCache, 0) == manifestContent
    check state.lastDetailIdx == -1
    check state.wrappedDetails.len == 0
    state.visibleAll = true
    state.visibleAllCount = 1
    var rendered = ""
    for row in 1 .. 4:
      renderDetails(rendered, state, row, 6, 80)
    check "Full Manifest" in rendered

    var fallback = Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: 0,
      pkgSlot: SlotNimble,
      quality: DetailFallback,
      content: "Name           : test-package\n",
    )
    update(state, fallback, 10)
    check detailCacheGet(state.detailsCache, 0) == manifestContent
