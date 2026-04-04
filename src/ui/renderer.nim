## UI component rendering.
## Split from tui.nim to keep modules manageable.

import std/[strutils, tables]
import ../core/[types, state]
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
    state: AppState,
    idx: int32,
    width: int,
    isCursor, isSelected: bool,
) =
  ## Renders a single row of the package list.
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
    buffer.appendSpaces(pad)

  if isCursor:
    buffer.add(Reset)

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
    if state.visibleIndices.len > 0:
      let curIdx = state.visibleIndices[state.cursor]
      if state.detailsCache.hasKey(curIdx):
        # Update wrapping cache if needed
        if state.lastDetailIdx != curIdx or state.lastDetailWidth != detailTextW:
          let rawContent = state.detailsCache[curIdx]
          state.wrappedDetails = wrapText(rawContent, detailTextW)
          state.lastDetailIdx = curIdx
          state.lastDetailWidth = detailTextW

        let effectiveIdx = contentRowIndex + state.detailScroll
        if effectiveIdx < state.wrappedDetails.len:
          textContent = state.wrappedDetails[effectiveIdx].replace("\t", "  ")
      elif contentRowIndex == 0:
        textContent = "..."

    let visLen = visibleWidth(textContent)
    if visLen > detailTextW:
      buffer.add(truncate(textContent, detailTextW))
    else:
      buffer.add(textContent)
      buffer.appendSpaces(detailTextW - visLen)
    buffer.add(ColorFrame & BoxVer & Reset)

proc renderStatusBar*(buffer: var string, state: AppState, termW: int): int =
  ## Renders the bottom status and search bar.
  let visLenStr = $state.visibleIndices.len
  let totalLenStr = $state.soa.hot.locators.len
  let pkgCountStrLen =
    if state.soa.hot.locators.len == 0:
      5 # "(...)"
    else:
      2 + visLenStr.len + 1 + totalLenStr.len

  let selCount = state.getSelectedCount()
  var statusPrefix = ""
  var statusPrefixLen = 0
  if selCount > 0:
    statusPrefix = ColorSel & "[" & $selCount & "] " & AnsiReset
    statusPrefixLen = 3 + ($selCount).len

  var modeStr = ""
  var modeStrLen = 0
  if state.viewingSelection:
    modeStr = ColorModeReview & "[Rev]" & AnsiReset
    modeStrLen = 5
  elif state.dataSource == SourceNimble:
    modeStr = ColorModeNimble & "[Nimble]" & AnsiReset
    modeStrLen = 8
  else:
    if state.searchMode == ModeAUR:
      modeStr = ColorModeAur & "[Aur]" & AnsiReset
      modeStrLen = 5
    else:
      modeStr = ColorModeLocal & "[Local]" & AnsiReset
      modeStrLen = 7

  var statusMsgStr = ""
  if state.statusMessage.len > 0:
    statusMsgStr = " " & AnsiBold & state.statusMessage & AnsiReset
    modeStrLen += 1 + state.statusMessage.len

  let cursorVisualX = 2 + visibleWidth(state.searchBuffer[0 ..< state.searchCursor])

  let leftSideLen = 2 + state.searchBuffer.len
  let rightSideLen = statusPrefixLen + modeStrLen + 1 + pkgCountStrLen
  let spacing = max(0, termW - leftSideLen - rightSideLen)

  # Start building the status bar
  buffer.add(ColorPrompt)
  buffer.add(">")
  buffer.add(AnsiReset)
  buffer.add(" ")
  buffer.add(state.searchBuffer)

  buffer.appendSpaces(spacing)

  buffer.add(statusPrefix)
  buffer.add(modeStr)
  buffer.add(statusMsgStr)
  buffer.add(" ")

  # Pkg Count
  buffer.add(AnsiDim)
  buffer.add("(")
  if state.soa.hot.locators.len == 0:
    buffer.add("...")
  else:
    buffer.add(visLenStr)
    buffer.add("/")
    buffer.add(totalLenStr)
  buffer.add(")")
  buffer.add(AnsiReset)

  return cursorVisualX
