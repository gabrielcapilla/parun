import unittest
import std/[monotimes, times, strutils]
import ../src/utils/nUtils

suite "nUtils - getRawBaseUrl":
  test "GitHub URL estándar":
    check getRawBaseUrl("https://github.com/user/repo.git") ==
      "https://raw.githubusercontent.com/user/repo"

  test "GitHub URL con trailing slash":
    check getRawBaseUrl("https://github.com/user/repo/") ==
      "https://raw.githubusercontent.com/user/repo"

  test "GitHub URL con (git) suffix":
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

  test "URL no soportada retorna vacío":
    check getRawBaseUrl("https://bitbucket.org/user/repo") == ""

  test "URL vacía":
    check getRawBaseUrl("") == ""

  test "URL con múltiples slashes":
    # Nota: La función solo elimina un slash, no múltiples
    check getRawBaseUrl("https://github.com/user/repo///") ==
      "https://raw.githubusercontent.com/user/repo//"

  test "URL con espacios":
    check getRawBaseUrl("  https://github.com/user/repo.git  ") ==
      "https://raw.githubusercontent.com/user/repo"

suite "nUtils - parseNimbleInfo":
  test "Archivo nimble básico":
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

  test "Archivo nimble con requires":
    let raw =
      """
      requires "nim >= 2.0", "stdlib"
      version = "1.0.0"
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Requires")
    check result.contains("- nim >= 2.0")
    check result.contains("- stdlib")

  test "Requires con paréntesis":
    let raw =
      """
      requires ("nim >= 2.0", "stdlib")
      version = "1.0.0"
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Requires")

  test "Archivo vacío":
    let result = parseNimbleInfo("", "pkgname", "url", @[])
    check result.contains("Name           : pkgname")
    check result.contains("URL            : url")

  test "Comillas en valores":
    let raw =
      """
      version = "1.0.0"
      author = "\"Test Author\""
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Test Author")

  test "Múltiples comentarios":
    let raw =
      """
      # Comment 1
      # Comment 2
      version = "1.0.0"
      # Comment 3
      """
    let result = parseNimbleInfo(raw, "pkgname", "url", @[])
    check result.contains("Version        : 1.0.0")

suite "nUtils - formatFallbackInfo":
  test "Output de nimble search":
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

  test "Líneas vacías ignoradas":
    let raw =
      """

pkgname:
  version: 1.0.0


      """
    let result = formatFallbackInfo(raw)
    check result.contains("Name")

  test "Sin colon en nombre de paquete":
    let raw =
      """
      pkgname version: 1.0.0
      """
    let result = formatFallbackInfo(raw)
    check result.contains("(Info from local nimble search cache)")

suite "nUtils - Performance":
  test "Benchmark getRawBaseUrl (1000 iteraciones)":
    let url = "https://github.com/user/repo.git"
    let start = getMonoTime()
    for i in 0 ..< 1000:
      discard getRawBaseUrl(url)
    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 10 # Debe ser < 10ms

  test "Benchmark parseNimbleInfo archivo grande":
    var raw = ""
    for i in 0 ..< 100:
      raw &= "field" & $i & " = \"value" & $i & "\"\n"
    let start = getMonoTime()
    for i in 0 ..< 100:
      discard parseNimbleInfo(raw, "pkgname", "url", @[])
    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 100 # Debe ser < 100ms
