## Main UI orchestration.

import std/[strformat, strutils]
import ../core/[types, state]
import renderer

type RenderResult* = tuple[cursorX: int, cursorY: int]

proc renderUi*(state: AppState, buffer: var string, termH, termW: int): RenderResult =
  ## Main rendering function. Fills the buffer with the complete frame.
  buffer.setLen(0)
  if termW < MinTermWidth or termH < MinTermHeight:
    buffer.add("\e[2J\e[H" & fmt"{AnsiBold}Terminal size too small.{AnsiReset}")
    return (0, 0)

  let listH = max(1, termH - 2)
  let showDetails = state.showDetails
  let listW =
    if showDetails:
      termW div 2
    else:
      termW
  let detailTotalW =
    if showDetails:
      termW - listW
    else:
      0
  let detailTextW = max(0, detailTotalW - 2)

  for r in 0 ..< listH:
    let rowIdx = state.scroll + (listH - 1 - r)
    if rowIdx >= 0 and rowIdx < state.visibleIndices.len:
      let realIdx = state.visibleIndices[rowIdx]
      appendRow(
        buffer,
        state,
        realIdx,
        listW,
        rowIdx == state.cursor,
        state.isSelected(int(realIdx)),
      )
    else:
      buffer.add(repeat(" ", listW))

    if showDetails:
      renderDetails(buffer, state, r, listH, detailTextW)
    buffer.add("\n")

  buffer.add(ColorFrame & repeat(BoxHor, termW) & Reset & "\n")
  let cx = renderStatusBar(buffer, state, termW)
  return (cx, termH)
