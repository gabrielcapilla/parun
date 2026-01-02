import unittest
import std/[monotimes, times, strutils, tables]
import ../src/utils/pacman

suite "pacman - parseInstalledPackages":
  test "Standard pacman -Q output":
    let output =
      """
pacman 6.0.2-2
linux-firmware 20241119.6d0ed8e-1
"""
    let result = parseInstalledPackages(output)
    check len(result) == 2
    check result["pacman"] == "6.0.2-2"
    check result["linux-firmware"] == "20241119.6d0ed8e-1"

  test "Output with empty lines":
    let output =
      """

pacman 6.0.2-2

linux-firmware 20241119.6d0ed8e-1

"""
    let result = parseInstalledPackages(output)
    check len(result) == 2

  test "Incomplete line (name only)":
    let output =
      """
pacman
linux-firmware 1.0.0
"""
    let result = parseInstalledPackages(output)
    check len(result) == 1
    check "linux-firmware" in result

  test "Empty output":
    let result = parseInstalledPackages("")
    check len(result) == 0

  test "Package with multiple spaces":
    let output = "package-name    1.0.0-1"
    let result = parseInstalledPackages(output)
    # split(' ') creates multiple empty strings
    # The function only saves if parts.len > 1
    # So it only saves "package-name" -> "" and then "" -> "1.0.0-1"
    # The final result depends on iteration order
    check len(result) == 1

  test "Version with hyphens and dots":
    let output = "complex-pkg 2.1.0-beta.3+20241201-1"
    let result = parseInstalledPackages(output)
    check result["complex-pkg"] == "2.1.0-beta.3+20241201-1"

suite "pacman - isPackageInstalled":
  test "[installed] marker in English":
    check isPackageInstalled("core pacman 6.0.2-2 [installed]") == true

  test "[instalado] marker in Spanish":
    check isPackageInstalled("core pacman 6.0.2-2 [instalado]") == true

  test "No marker":
    check isPackageInstalled("core pacman 6.0.2-2") == false

  test "Marker at end":
    check isPackageInstalled("extra gcc 14.2.1+20241130-1 [installed]") == true

  test "Edge case - multiple brackets":
    check isPackageInstalled("extra pkg[brackets] 1.0.0 [installed]") == true

  test "Edge case - brackets in name":
    # The function only looks for [installed] or [instalado]
    # [bracketed] is not a valid installation marker
    check isPackageInstalled("extra pkg[brackets] 1.0.0 [bracketed]") == false

  test "Empty line":
    check isPackageInstalled("") == false

  test "Marker only":
    check isPackageInstalled("[installed]") == true

suite "pacman - Performance":
  test "Benchmark parseInstalledPackages 10K packages":
    var output = ""
    for i in 0 ..< 10000:
      output &= "pkg" & $i & " " & $i & ".0.0-1\n"
    let start = getMonoTime()
    let result = parseInstalledPackages(output)
    let elapsed = getMonoTime() - start
    check len(result) == 10000
    check elapsed.inMilliseconds < 100 # Should be < 100ms
