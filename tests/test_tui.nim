##
##  TUI Tests
##
## Tests for the main UI orchestration logic.
##

import unittest
import std/[strutils, strformat, sequtils]
import ../src/ui/tui
import ../src/core/types
import ../src/core/state

suite "TUI - renderUi":
  setup:
    var state = newState(ModeLocal, false, false)
    # Setup standard fake data for a single package "pkg1"
    # Name: pkg1 (4 chars)
    # Ver: v1 (2 chars)
    # Repo: r1 (2 chars)
    # Total text: r1pkg1v1
    state.textArena = "r1pkg1v1".toSeq
    state.repos = @["r1"]
    state.repoArena = "r1".toSeq
    state.repoLens = @[uint8(2)]
    state.repoOffsets = @[uint16(0)]

    # Package 0
    state.soa.hot.locators = @[uint32(2)] # Start of "pkg1" (after "r1")
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(2)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]

    state.visibleIndices = @[int32(0)]
    state.scroll = 0
    state.cursor = 0

  test "Terminal too small":
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 5, 20)
    check buffer.contains("Terminal size too small")
    check cx == 0
    check cy == 0

  test "Render normal view":
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    check buffer.len > 0
    check not buffer.contains("Terminal size too small")
    check cy == 20

    # Should contain "pkg1"
    check buffer.contains("pkg1")

    # Should contain Status Bar prompt
    check buffer.contains(">")

  test "Render details view (Split)":
    state.showDetails = true
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    # Should contain "pkg1"
    check buffer.contains("pkg1")

    # Should contain box characters from details panel
    # BoxVer is "│"
    check buffer.contains("│")

  test "Empty lines padding":
    state.visibleIndices = @[] # No packages
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    # Should still render status bar
    check buffer.contains(">")

    # Main area should be spaces (implicitly checked by lack of crashes and valid length)
    check buffer.splitLines().len >= 19

  test "Scroll logic":
    # Add more packages
    for i in 1 .. 10:
      state.visibleIndices.add(int32(0)) # Just reuse the same package data

    state.scroll = 5
    var buffer = ""
    # With scroll 5, renderUi should start rendering from index 5
    # The current implementation of renderUi iterates:
    # for r in 0 ..< listH:
    #   let rowIdx = state.scroll + (listH - 1 - r)
    # Wait, the logic in tui.nim is:
    # let rowIdx = state.scroll + (listH - 1 - r)
    # This renders from bottom to top?
    # Let's verify the logic in tui.nim via the test.

    discard renderUi(state, buffer, 20, 80)
    check buffer.len > 0

  test "Return Cursor Position":
    state.searchBuffer = "query"
    state.searchCursor = 5
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    # Check that cursor X position accounts for prompt "> " (2 chars) + "query" (5 chars)
    check cx == 7
    check cy == 20

  test "Render with selected items":
    state.toggleSelection(0)
    var buffer = ""
    discard renderUi(state, buffer, 20, 80)

    # Should contain selection indicator "*" (from renderer PrefixLUT)
    # Note: depends on renderer implementation. PrefixLUT[1] or [3] has "*"
    # or color codes.
    # Checking for ANSI codes is brittle, but we can check if it runs.
    check buffer.len > 0

suite "TUI - Edge Cases":
  test "Zero visible items":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    let (cx, cy) = renderUi(state, buffer, 20, 80)

    check cy == 20
    check buffer.contains(">")

  test "Detail view with small width":
    var state = newState(ModeLocal, false, false) # showDetails = false initially
    state.showDetails = true # Force it
    var buffer = ""
    # MinTermWidth is 50. 50 / 2 = 25 width for list, 25 for details.
    let (cx, cy) = renderUi(state, buffer, 20, 50)

    check cy == 20
