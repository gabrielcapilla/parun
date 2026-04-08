## UI component rendering.
## Split from tui.nim to keep modules manageable.

import std/[monotimes, strutils, times]
import ../core/[types, state]
import ../storage/indexes
import ../utils/utils

const
  MinTermWidth* = 80
  MinTermHeight* = 15
  BoxTopLeft* = "╭"
  BoxTopRight* = "╮"
  BoxBottomLeft* = "╰"
  BoxBottomRight* = "╯"
  BoxHor* = "─"
  BoxVer* = "│"
  ColorFrame* = "\e[90m"
  Reset* = "\e[0m"

  PrefixLUT* = ["  ", "\e[93m*\e[0m ", "\e[48;5;235m  ", "\e[48;5;235m\e[93m* "]

  SepSlash = "/"
  Space = " "
  InstalledTag* = " \e[36m[installed]\e[0m"
  PrefixLen* = 2
  InstalledLen* = 12
  Spaces50* = "                                                  "

proc appendSpaces*(buffer: var string, count: int) =
  var p = count
  while p >= 50:
    buffer.add(Spaces50)
    p -= 50
  for _ in 0 ..< p:
    buffer.add(' ')

proc appendRow*(
    buffer: var string,
    view: ptr SourceIndexView,
    idx: int32,
    width: int,
    isCursor, isSelected: bool,
) =
  ## Renders a single row of the package list.
  let i = int(idx)
  let isInstalled = isInstalled(view, i)
  let tagW = if isInstalled: InstalledLen else: 0
  let maxTextW = max(0, width - PrefixLen - tagW)

  let repoLen = getRepoLen(view, i)
  let nameLen = getNameLen(view, i)
  let verLen = getVersionLen(view, i)

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
    appendRepo(view, i, buffer, printRepoLen)
    if hasSlash:
      buffer.add(SepSlash)
      appendName(view, i, buffer, printNameLen)
    if hasSpace:
      buffer.add(Space)
      appendVersion(view, i, buffer, printVerLen)
  else:
    buffer.add(ColorRepo)
    appendRepo(view, i, buffer, printRepoLen)
    buffer.add(Reset)

    if hasSlash:
      buffer.add(SepSlash)
      buffer.add(ColorPkg)
      buffer.add(AnsiBold)
      appendName(view, i, buffer, printNameLen)
      buffer.add(Reset)

    if hasSpace:
      buffer.add(Space)
      buffer.add(ColorVer)
      appendVersion(view, i, buffer, printVerLen)
      buffer.add(Reset)

  if isInstalled:
    buffer.add(InstalledTag)

  let usedLen =
    PrefixLen + printRepoLen + (if hasSlash: 1 else: 0) + printNameLen +
    (if hasSpace: 1 else: 0) + printVerLen + tagW
  let pad = max(0, width - usedLen)

  if pad > 0:
    buffer.appendSpaces(pad)

  if isCursor:
    buffer.add(Reset)

proc loadingIndicatorLine(width: int, row: int, phase: int): string =
  discard phase
  if width <= 0:
    return ""

  if row == 0:
    return AnsiDim & "..." & AnsiReset
  return ""

proc renderDetails*(
    buffer: var string, state: var AppState, r, listH, detailTextW: int
) =
  ## Renders the side details panel with dynamic text wrapping.
  if r == 0:
    buffer.add(ColorFrame)
    buffer.add(BoxTopLeft)
    for _ in 0 ..< detailTextW:
      buffer.add(BoxHor)
    buffer.add(BoxTopRight)
    buffer.add(Reset)
  elif r == listH - 1:
    buffer.add(ColorFrame)
    buffer.add(BoxBottomLeft)
    for _ in 0 ..< detailTextW:
      buffer.add(BoxHor)
    buffer.add(BoxBottomRight)
    buffer.add(Reset)
  else:
    buffer.add(ColorFrame)
    buffer.add(BoxVer)
    buffer.add(Reset)
    let contentRowIndex = r - 1
    var textContent = ""
    if state.visibleCount() > 0:
      let curIdx = state.visibleIdxAt(state.cursor)
      if detailCacheHas(state.detailsCache, curIdx):
        if contentRowIndex == 0:
          state.perf.coldDetailCacheHits.inc()
        # Update wrapping cache if needed
        if state.lastDetailIdx != curIdx or state.lastDetailWidth != detailTextW:
          let rawContent = detailCacheGet(state.detailsCache, curIdx)
          state.wrappedDetails = wrapText(rawContent, detailTextW)
          state.lastDetailIdx = curIdx
          state.lastDetailWidth = detailTextW
          state.perf.coldDetailWraps.inc()

        let effectiveIdx = contentRowIndex + state.detailScroll
        if effectiveIdx < state.wrappedDetails.len:
          textContent = state.wrappedDetails[effectiveIdx].replace("\t", "  ")
          state.perf.coldDetailLines.inc()
      else:
        if contentRowIndex == 0:
          state.perf.coldDetailCacheMisses.inc()
        let loadingMs = int((getMonoTime() - state.detailTargetSince).inMilliseconds())
        let phase = loadingMs div 80
        textContent = loadingIndicatorLine(detailTextW, contentRowIndex, phase)

    let visLen = visibleWidth(textContent)
    if visLen > detailTextW:
      buffer.add(truncate(textContent, detailTextW))
    else:
      buffer.add(textContent)
      buffer.appendSpaces(detailTextW - visLen)
    buffer.add(ColorFrame & BoxVer & Reset)

proc renderStatusBar*(
    buffer: var string,
    visibleCount, totalCount: int,
    selectionBits: openArray[uint64],
    viewingSelection: bool,
    dataSource: DataSource,
    searchMode: SearchMode,
    statusMessage, searchBuffer: string,
    searchCursor, termW: int,
): int =
  ## Renders the bottom status and search bar.
  let visLenStr = $visibleCount
  let totalLenStr = $totalCount
  let pkgCountStrLen =
    if totalCount == 0:
      5 # "(...)"
    else:
      2 + visLenStr.len + 1 + totalLenStr.len

  let selCount = getSelectedCount(selectionBits)
  var statusPrefix = ""
  var statusPrefixLen = 0
  if selCount > 0:
    statusPrefix = ColorSel & "[" & $selCount & "] " & AnsiReset
    statusPrefixLen = 3 + ($selCount).len

  var modeStr = ""
  var modeStrLen = 0
  if viewingSelection:
    modeStr = ColorModeReview & "[Rev]" & AnsiReset
    modeStrLen = 5
  elif dataSource == SourceNimble:
    modeStr = ColorModeNimble & "[Nimble]" & AnsiReset
    modeStrLen = 8
  else:
    if searchMode == ModeAUR:
      modeStr = ColorModeAur & "[Aur]" & AnsiReset
      modeStrLen = 5
    else:
      modeStr = ColorModeLocal & "[Local]" & AnsiReset
      modeStrLen = 7

  var statusMsgStr = ""
  if statusMessage.len > 0:
    statusMsgStr = " " & AnsiBold & statusMessage & AnsiReset
    modeStrLen += 1 + statusMessage.len

  let cursorVisualX = 2 + visibleWidth(searchBuffer[0 ..< searchCursor])

  let leftSideLen = 2 + searchBuffer.len
  let rightSideLen = statusPrefixLen + modeStrLen + 1 + pkgCountStrLen
  let spacing = max(0, termW - leftSideLen - rightSideLen)

  # Start building the status bar
  buffer.add(ColorPrompt)
  buffer.add(">")
  buffer.add(AnsiReset)
  buffer.add(" ")
  buffer.add(searchBuffer)

  buffer.appendSpaces(spacing)

  buffer.add(statusPrefix)
  buffer.add(modeStr)
  buffer.add(statusMsgStr)
  buffer.add(" ")

  # Pkg Count
  buffer.add(AnsiDim)
  buffer.add("(")
  if totalCount == 0:
    buffer.add("...")
  else:
    buffer.add(visLenStr)
    buffer.add("/")
    buffer.add(totalLenStr)
  buffer.add(")")
  buffer.add(AnsiReset)

  return cursorVisualX
