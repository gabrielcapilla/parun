## UI component rendering.
## Split from tui.nim to keep modules manageable.
##
## Notes:
## - Consumes immutable index views + `AppState` to build one terminal frame.
## - Rendering is string-buffer based; no direct per-cell terminal writes.
## - Details panel uses cache-first policy and displays lightweight loading marker on misses.

import std/[monotimes, strutils, times, unicode]
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
  ## Fast-path space append using 50-char chunk constant.
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

proc loadingIndicatorLine(
    width: int, row: int, phase: int, style: DetailAnimationStyle
): string =
  ## Minimal loading placeholder in details panel.
  if width <= 0:
    return ""

  const LoadingText = "loading details"
  if row == 0:
    result = AnsiDim
    let reveal = min(LoadingText.len, phase mod (LoadingText.len + 1))
    for i in 0 ..< LoadingText.len:
      if i < reveal or LoadingText[i] == ' ':
        result.add(LoadingText[i])
      else:
        case style
        of DetailAnimationBlocks:
          case (phase + i * 3) and 3
          of 0:
            result.add("░")
          of 1:
            result.add("▒")
          of 2:
            result.add("▓")
          else:
            result.add("█")
        of DetailAnimationFade:
          result.add("·")
    result.add(AnsiReset)
    return
  return ""

func scrambleRank(seed: uint32, pos: int): uint32 {.inline.} =
  ## Stable per-cell rank: avoids storing/shuffling indices in the render loop.
  var x = seed xor uint32(pos * 0x45d9f3b)
  x = (x xor (x shr 16)) * 0x7feb352d'u32
  x = (x xor (x shr 15)) * 0x846ca68b'u32
  x xor (x shr 16)

proc scrambledDetailLine(
    text: string,
    pkgIdx: int32,
    row, elapsedMs, durationMs: int,
    style: DetailAnimationStyle,
): string =
  if text.len == 0 or durationMs <= 0 or elapsedMs >= durationMs:
    return text

  let width = visibleWidth(text)
  if width <= 0:
    return text

  let resolvedLimit = uint32((uint64(width) * uint64(elapsedMs)) div uint64(durationMs))
  let seed = uint32(pkgIdx) xor (uint32(row) * 0x9e3779b1'u32)
  result = newStringOfCap(text.len + width * 2)
  var i = 0
  var cell = 0
  while i < text.len:
    if text[i] == '\e':
      let start = i
      inc i
      if i < text.len and text[i] == '[':
        inc i
        while i < text.len and text[i] != 'm':
          inc i
        if i < text.len:
          inc i
      result.add(text[start ..< i])
      continue

    let rl = text.runeLenAt(i)
    if text[i] == ' ' or scrambleRank(seed, cell) mod uint32(width) < resolvedLimit:
      result.add(text[i ..< i + rl])
    else:
      case style
      of DetailAnimationBlocks:
        case (scrambleRank(seed xor uint32(elapsedMs div 24), cell) and 3)
        of 0:
          result.add("░")
        of 1:
          result.add("▒")
        of 2:
          result.add("▓")
        else:
          result.add("█")
      of DetailAnimationFade:
        result.add(AnsiDim)
        result.add(text[i ..< i + rl])
        result.add(AnsiReset)
    i += rl
    cell.inc()

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
          if state.detailsAnimationEnabled and state.detailScramble.active and
              state.detailScramble.pkgIdx == curIdx and
              state.detailScramble.pkgSlot == state.activeSlot:
            let elapsedMs =
              int((getMonoTime() - state.detailScramble.startedAt).inMilliseconds())
            if elapsedMs >= state.detailScramble.durationMs:
              state.detailScramble.active = false
            else:
              textContent = scrambledDetailLine(
                textContent, curIdx, effectiveIdx, elapsedMs,
                state.detailScramble.durationMs, state.detailAnimationStyle,
              )
              state.needsRedraw = true
          state.perf.coldDetailLines.inc()
      else:
        if contentRowIndex == 0:
          state.perf.coldDetailCacheMisses.inc()
        if state.detailsAnimationEnabled:
          let loadingMs =
            int((getMonoTime() - state.detailTargetSince).inMilliseconds())
          let phase = loadingMs div 80
          textContent = loadingIndicatorLine(
            detailTextW, contentRowIndex, phase, state.detailAnimationStyle
          )
          state.needsRedraw = true
        elif contentRowIndex == 0:
          textContent = AnsiDim & "loading details" & AnsiReset

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
    selectedCount: int,
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

  var statusPrefix = ""
  var statusPrefixLen = 0
  if selectedCount > 0:
    statusPrefix = ColorSel & "[" & $selectedCount & "] " & AnsiReset
    statusPrefixLen = 3 + ($selectedCount).len

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
      modeStr = ColorModeLocal & "[Pacman]" & AnsiReset
      modeStrLen = 8

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
