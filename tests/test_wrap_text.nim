import std/[strutils, unittest]

import ../src/utils/utils

suite "details text wrapping":
  test "field labels keep fixed-width padding when wrapped":
    let wrapped = wrapText(
      "Description     : Nim Language Server Protocol - nimlsp implements the Language Server Protocol",
      72,
    )

    check wrapped.len == 2
    check wrapped[0].startsWith("Description     : ")
    check wrapped[0] != "Description : Nim Language Server Protocol - nimlsp implements the"
    check wrapped[1].startsWith(spaces("Description     : ".len))
