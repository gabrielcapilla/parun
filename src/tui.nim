## Generates the character buffer to draw the interface.
## Optimized to minimize writes to STDOUT (Implicit Double Buffering).

import std/[strformat, strutils, tables]
import types, utils, state

const
  MinTermWidth = 50
  MinTermHeight = 10
  BoxTopLeft = "╭"
  BoxTopRight = "╮"
  BoxBottomLeft = "╰"
  BoxBottomRight = "╯"
  BoxHor = "─"
  BoxVer = "│"
  ColorFrame = "\e[90m"
  Reset = "\e[0m"

  PrefixLUT = ["  ", "\e[93m*\e[0m ", "\e[48;5;235m  ", "\e[48;5;235m\e[93m* "]

  SepSlash = "/"
  Space = " "
  InstalledTag = " \e[36m[installed]\e[0m"
  PrefixLen = 2
  InstalledLen = 12
  Spaces50 = "                                                  "

type RenderResult* = tuple[cursorX: int, cursorY: int]

func appendRow(
    buffer: var string,
    state: AppState,
    idx: int32,
    width: int,
    isCursor, isSelected: bool,
) =
  ## Renders a single row of the package list.
  ## Calculates text clipping to fit available width.
  let i = int(idx)
  let isInstalled = state.isInstalled(i)
  let tagW = if isInstalled: InstalledLen else: 0
  let maxTextW = max(0, width - PrefixLen - tagW)

  let repoLen = state.getRepoLen(i)
  let nameLen = state.getNameLen(i)
  let verLen = state.getVersionLen(i)

  var printRepoLen = repoLen
  var printNameLen = nameLen
  var printVerLen = verLen
  var hasSlash = (nameLen > 0)
  var hasSpace = (verLen > 0)

  let totalNeeded =
    repoLen + (if hasSlash: 1 else: 0) + nameLen + (if hasSpace: 1 else: 0) + verLen

  if totalNeeded > maxTextW:
    let repoNameLen = repoLen + (if hasSlash: 1 else: 0) + nameLen
    if repoNameLen + (if hasSpace: 1 else: 0) < maxTextW:
      let roomForVer = maxTextW - repoNameLen - (if hasSpace: 1 else: 0)
      printVerLen = max(0, roomForVer)
      if printVerLen == 0:
        hasSpace = false
    else:
      printVerLen = 0
      hasSpace = false
      let roomForName = maxTextW - repoLen - (if hasSlash: 1 else: 0)
      if roomForName > 0:
        printNameLen = min(nameLen, roomForName)
      else:
        printNameLen = 0
        hasSlash = false
        printRepoLen = min(repoLen, maxTextW)

  let styleIdx = (isCursor.int shl 1) or isSelected.int

  buffer.add(PrefixLUT[styleIdx])

  if isCursor:
    state.appendRepo(i, buffer, printRepoLen)
    if hasSlash:
      buffer.add(SepSlash)
      state.appendName(i, buffer, printNameLen)
    if hasSpace:
      buffer.add(Space)
      state.appendVersion(i, buffer, printVerLen)
  else:
    buffer.add(ColorRepo)
    state.appendRepo(i, buffer, printRepoLen)
    buffer.add(Reset)

    if hasSlash:
      buffer.add(SepSlash)
      buffer.add(ColorPkg)
      buffer.add(AnsiBold)
      state.appendName(i, buffer, printNameLen)
      buffer.add(Reset)

    if hasSpace:
      buffer.add(Space)
      buffer.add(ColorVer)
      state.appendVersion(i, buffer, printVerLen)
      buffer.add(Reset)

  if isInstalled:
    buffer.add(InstalledTag)

  let usedLen =
    PrefixLen + printRepoLen + (if hasSlash: 1 else: 0) + printNameLen +
    (if hasSpace: 1 else: 0) + printVerLen + tagW
  let pad = max(0, width - usedLen)

  if pad > 0:
    var p = pad
    while p >= 50:
      buffer.add(Spaces50)
      p -= 50
    if p > 0:
      buffer.add(Spaces50[0 ..< p])

  if isCursor:
    buffer.add(Reset)

func renderDetails(buffer: var string, state: AppState, r, listH, detailTextW: int) =
  ## Renders the side details panel.
  if r == 0:
    buffer.add(
      ColorFrame & BoxTopLeft & repeat(BoxHor, detailTextW) & BoxTopRight & Reset
    )
  elif r == listH - 1:
    buffer.add(
      ColorFrame & BoxBottomLeft & repeat(BoxHor, detailTextW) & BoxBottomRight & Reset
    )
  else:
    buffer.add(ColorFrame & BoxVer & Reset)
    let contentRowIndex = r - 1
    var textContent = ""
    if state.visibleIndices.len > 0:
      let curIdx = state.visibleIndices[state.cursor]
      if state.detailsCache.hasKey(curIdx):
        let dLines = state.detailsCache[curIdx].splitLines
        let effectiveIdx = contentRowIndex + state.detailScroll
        if effectiveIdx < dLines.len:
          textContent = dLines[effectiveIdx].replace("\t", "  ")
      elif contentRowIndex == 0:
        textContent = "..."

    let visLen = visibleWidth(textContent)
    if visLen > detailTextW:
      buffer.add(truncate(textContent, detailTextW))
    else:
      buffer.add(textContent)
      buffer.add(repeat(" ", detailTextW - visLen))
    buffer.add(ColorFrame & BoxVer & Reset)

func renderStatusBar(buffer: var string, state: AppState, termW: int): int =
  ## Renders the bottom status and search bar.
  let pkgCountStr =
    if state.soa.hot.locators.len == 0:
      fmt"{AnsiDim}(...){AnsiReset}"
    else:
      fmt"{AnsiDim}({state.visibleIndices.len}/{state.soa.hot.locators.len}){AnsiReset}"

  let selCount = state.getSelectedCount()
  let statusPrefix =
    if selCount > 0:
      fmt"{ColorSel}[{selCount}]{AnsiReset} "
    else:
      ""

  var modeStr = ""
  if state.viewingSelection:
    modeStr = fmt"{ColorModeReview}[Rev]{AnsiReset}"
  elif state.dataSource == SourceNimble:
    modeStr = fmt"{ColorModeNimble}[Nimble]{AnsiReset}"
  else:
    if state.searchMode == ModeAUR:
      modeStr = fmt"{ColorModeAur}[Aur]{AnsiReset}"
    else:
      modeStr = fmt"{ColorModeLocal}[Local]{AnsiReset}"

  if state.statusMessage.len > 0:
    modeStr.add(fmt" {AnsiBold}{state.statusMessage}{AnsiReset}")

  let leftSide = fmt"{ColorPrompt}>{AnsiReset} {state.searchBuffer}"
  let cursorVisualX =
    if state.searchBuffer.len > 0 and state.searchCursor > 0:
      2 + visibleWidth(state.searchBuffer[0 ..< state.searchCursor])
    else:
      2

  let leftSideClean = "> " & state.searchBuffer
  let rightSide = fmt"{statusPrefix}{modeStr} {pkgCountStr}"
  let spacing = max(0, termW - visibleWidth(leftSideClean) - visibleWidth(rightSide))

  buffer.add(leftSide)
  buffer.add(repeat(" ", spacing))
  buffer.add(rightSide)
  return cursorVisualX

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
