## Main UI orchestration.
##
## Notes:
## - Produces complete frame buffer and cursor coordinates per tick.
## - Delegates row/details/status rendering to `ui/renderer`.
## - Keeps all terminal escape sequencing centralized in one pass.

import std/[sets, strformat]
import ../core/[types, state]
import ../storage/indexes
import renderer

type RenderResult* = tuple[cursorX: int, cursorY: int]

proc renderUi*(
    state: var AppState, buffer: var string, termH, termW: int
): RenderResult =
  ## Main rendering function. Fills the buffer with the complete frame.
  buffer.setLen(0)
  if termW < MinTermWidth or termH < MinTermHeight:
    ## Clear screen and show centered error message with size information
    ## Using \x1B instead of \e for escape character (more reliable)
    const ESC = "\x1B"
    const AnsiRed = "\x1B[91m"
    const AnsiGreen = "\x1B[92m"
    const AnsiWhite = "\x1B[97m"

    buffer.add(ESC & "[2J") # Clear screen

    # Calculate vertical center
    let centerY = termH div 2
    let startY = max(0, centerY - 2)

    # Determine colors for current dimensions (red if too small, green if OK)
    let widthColor = if termW < MinTermWidth: AnsiRed else: AnsiGreen
    let heightColor = if termH < MinTermHeight: AnsiRed else: AnsiGreen

    # Build lines with proper formatting
    # Line 1: Title (white bold)
    let line1 = "Terminal size too small:"
    let line1Width = line1.len
    let x1 = max(0, (termW - line1Width) div 2)
    buffer.add(fmt"{ESC}[{startY + 1};{x1 + 1}H{AnsiBold}{AnsiWhite}{line1}{AnsiReset}")

    # Line 2: Current dimensions with conditional coloring
    # Format: "Width = [color]N[reset] Height = [color]N[reset]"
    let line2Prefix = "Width = "
    let line2Middle = " Height = "
    let termWStr = $termW
    let termHStr = $termH
    let line2Width = line2Prefix.len + termWStr.len + line2Middle.len + termHStr.len
    let x2 = max(0, (termW - line2Width) div 2)
    buffer.add(
      fmt"{ESC}[{startY + 2};{x2 + 1}H{AnsiBold}{AnsiWhite}{line2Prefix}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 2};{x2 + 1 + line2Prefix.len}H{AnsiBold}{widthColor}{termW}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 2};{x2 + 1 + line2Prefix.len + termWStr.len}H{AnsiBold}{AnsiWhite}{line2Middle}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 2};{x2 + 1 + line2Prefix.len + termWStr.len + line2Middle.len}H{AnsiBold}{heightColor}{termH}{AnsiReset}"
    )

    # Line 3: Empty

    # Line 4: Subtitle (white bold)
    let line4 = "Needed for current config:"
    let line4Width = line4.len
    let x4 = max(0, (termW - line4Width) div 2)
    buffer.add(fmt"{ESC}[{startY + 4};{x4 + 1}H{AnsiBold}{AnsiWhite}{line4}{AnsiReset}")

    # Line 5: Required dimensions (always green)
    let line5Prefix = "Width = "
    let line5Middle = " Height = "
    let minWStr = $MinTermWidth
    let minHStr = $MinTermHeight
    let line5Width = line5Prefix.len + minWStr.len + line5Middle.len + minHStr.len
    let x5 = max(0, (termW - line5Width) div 2)
    buffer.add(
      fmt"{ESC}[{startY + 5};{x5 + 1}H{AnsiBold}{AnsiWhite}{line5Prefix}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 5};{x5 + 1 + line5Prefix.len}H{AnsiBold}{AnsiGreen}{MinTermWidth}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 5};{x5 + 1 + line5Prefix.len + minWStr.len}H{AnsiBold}{AnsiWhite}{line5Middle}{AnsiReset}"
    )
    buffer.add(
      fmt"{ESC}[{startY + 5};{x5 + 1 + line5Prefix.len + minWStr.len + line5Middle.len}H{AnsiBold}{AnsiGreen}{MinTermHeight}{AnsiReset}"
    )

    return (0, 0)

  let listH = max(1, termH - 2)
  # Auto-hide details panel when terminal is too small for comfortable viewing
  # Threshold: width < 100 or height < 26 (based on empirical testing with stty size)
  const DetailsMinWidth = 100
  const DetailsMinHeight = 26
  let showDetails =
    state.showDetails and (termW >= DetailsMinWidth) and (termH >= DetailsMinHeight)
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
  let view = state.activeView
  const ColdPredecodeLookaheadRows = 3

  if state.visibleCount() > 0:
    let predecodeStart = max(0, state.scroll - ColdPredecodeLookaheadRows)
    let predecodeEnd = min(
      state.visibleCount() - 1, state.scroll + listH - 1 + ColdPredecodeLookaheadRows
    )
    for rowIdx in predecodeStart .. predecodeEnd:
      predecodeColdFields(view, int(state.visibleIdxAt(rowIdx)))

  for r in 0 ..< listH:
    let rowIdx = state.scroll + (listH - 1 - r)
    if rowIdx >= 0 and rowIdx < state.visibleCount():
      let realIdx = state.visibleIdxAt(rowIdx)
      state.perf.coldRowRenders.inc()
      appendRow(
        buffer,
        view,
        realIdx,
        listW,
        rowIdx == state.cursor,
        state.isSelectedPackage(view, int(realIdx)),
      )
    else:
      buffer.appendSpaces(listW)

    if showDetails:
      renderDetails(buffer, state, r, listH, detailTextW)
    buffer.add("\n")

  buffer.add(ColorFrame)
  for _ in 0 ..< termW:
    buffer.add(BoxHor)
  buffer.add(Reset & "\n")
  let cx = renderStatusBar(
    buffer,
    state.visibleCount(),
    packageCount(view),
    len(state.selectedPackages),
    state.viewingSelection,
    state.dataSource,
    state.searchMode,
    state.statusMessage,
    state.searchBuffer,
    state.searchCursor,
    termW,
  )
  return (cx, termH)
