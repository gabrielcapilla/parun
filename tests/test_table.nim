import std/[tables, strutils, unittest]
import ../src/utils/pacman

suite "Test":
  test "Test":
    let output = "a 1\n"
    let result = parseInstalledPackages(output)
    check len(result) == 1
