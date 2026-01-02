import unittest
import std/[monotimes, times, strutils]
import ../src/utils/nimble

suite "nimble - getRawBaseUrl":
  test "Standard GitHub URL":
    check getRawBaseUrl("https://github.com/user/repo.git") ==
      "https://raw.githubusercontent.com/user/repo"

  test "GitHub URL with trailing slash":
    check getRawBaseUrl("https://github.com/user/repo/") ==
      "https://raw.githubusercontent.com/user/repo"

  test "GitHub URL with (git) suffix":
    check getRawBaseUrl("https://github.com/user/repo (git)") ==
      "https://raw.githubusercontent.com/user/repo"

  test "GitLab URL":
    check getRawBaseUrl("https://gitlab.com/user/repo.git") ==
      "https://gitlab.com/user/repo/-/raw"

  test "Codeberg URL":
    check getRawBaseUrl("https://codeberg.org/user/repo.git") ==
      "https://codeberg.org/user/repo/raw/branch"

  test "Sourcehut URL":
    check getRawBaseUrl("https://git.sr.ht/~user/repo") ==
      "https://git.sr.ht/~user/repo/blob"

  test "Unsupported URL returns empty":
    check getRawBaseUrl("https://bitbucket.org/user/repo") == ""

  test "Empty URL":
    check getRawBaseUrl("") == ""

  test "URL with multiple slashes":
    # Note: The function only removes one slash, not multiple
    check getRawBaseUrl("https://github.com/user/repo///") ==
      "https://raw.githubusercontent.com/user/repo//"

  test "URL with spaces":
    check getRawBaseUrl("  https://github.com/user/repo.git  ") ==
      "https://raw.githubusercontent.com/user/repo"

suite "nimble - parseNimbleInfo":
  test "Basic nimble file":
    let raw =
      """
      # Comment
      version       = "1.0.0"
      author        = "Test Author"
      description   = "Test package"
      license       = "MIT"
      """
    let result = parseNimbleInfo(raw, "pkgname", "https://github.com/user/repo", @[])
    check result.contains("Name           : pkgname")
    check result.contains("Version        : 1.0.0")
    check result.contains("Author         : Test Author")

  test "Nimble file with requires":
    let raw =
      """
      requires "nim >= 2.0", "stdlib"
      version = "1.0.0"
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Requires")
    check result.contains("- nim >= 2.0")
    check result.contains("- stdlib")

  test "Requires with parentheses":
    let raw =
      """
      requires ("nim >= 2.0", "stdlib")
      version = "1.0.0"
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Requires")

  test "Empty file":
    let result = parseNimbleInfo("", "pkgname", "url", @[])
    check result.contains("Name           : pkgname")
    check result.contains("URL            : url")

  test "Quotes in values":
    let raw =
      """
      version = "1.0.0"
      author = "\"Test Author\""
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Test Author")

  test "Multiple comments":
    let raw =
      """
      # Comment 1
      # Comment 2
      version = "1.0.0"
      # Comment 3
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Version        : 1.0.0")

suite "nimble - formatFallbackInfo":
  test "Output from nimble search":
    let raw =
      """
pkgname:
  version: 1.0.0
  url: https://github.com/user/repo
  description: Test package
  tags: tag1, tag2
  license: MIT
      """
    let result = formatFallbackInfo(raw)
    check result.contains("Name           : pkgname")
    check result.contains("Version        : 1.0.0")
    check result.contains("(Info from local nimble search cache)")

  test "Empty lines ignored":
    let raw =
      """

pkgname:
  version: 1.0.0


      """
    let result = formatFallbackInfo(raw)
    check result.contains("Name")

  test "No colon in package name":
    let raw =
      """
      pkgname version: 1.0.0
      """
    let result = formatFallbackInfo(raw)
    check result.contains("(Info from local nimble search cache)")

suite "nimble - Performance":
  test "Benchmark getRawBaseUrl (1000 iterations)":
    let url = "https://github.com/user/repo.git"
    let start = getMonoTime()
    for i in 0 ..< 1000:
      discard getRawBaseUrl(url)
    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 10 # Should be < 10ms

  test "Benchmark parseNimbleInfo large file":
    var raw = ""
    for i in 0 ..< 100:
      raw &= "field" & $i & " = \"value" & $i & "\"\n"
    let start = getMonoTime()
    for i in 0 ..< 100:
      discard parseNimbleInfo(raw, "pkgname", "url", @[])
    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 100 # Should be < 100ms
