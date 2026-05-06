import std/[strutils, unittest]

import ../src/plugins/nimble

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
    check "Description     : Nim Language Server Protocol - nimlsp implements the Language Server Protocol" in info
    check "URL             : https://github.com/PMunch/nimlsp" in info
    check "Licenses        : MIT" in info
    check "Author          : PMunch" in info
    check "Depends On      : nim >= 1.0.0, jsonschema >= 0.2.1, asynctools >= 0.1.1" in info

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
