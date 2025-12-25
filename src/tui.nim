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
  let i = int(idx)
  let isInstalled = state.soa.flags[i].isInstalled
  let tagW = if isInstalled: InstalledLen else: 0
  let maxTextW = max(0, width - PrefixLen - tagW)

  var dRepo = state.getRepo(i)
  var dName = state.getName(i)
  var dVer = state.getVersion(i)

  let currentLen = dRepo.len + 1 + dName.len + 1 + dVer.len
  if currentLen > maxTextW:
    let repoNameLen = dRepo.len + 1 + dName.len
    if repoNameLen + 1 < maxTextW:
      let roomForVer = maxTextW - repoNameLen - 1
      dVer =
        if roomForVer > 0:
          dVer[0 ..< min(dVer.len, roomForVer)]
        else:
          ""
    else:
      dVer = ""
      let roomForName = maxTextW - dRepo.len - 1
      if roomForName > 0:
        dName = dName[0 ..< min(dName.len, roomForName)]
      else:
        dName = ""
        dRepo = dRepo[0 ..< min(dRepo.len, maxTextW)]

  let styleIdx = (isCursor.int shl 1) or isSelected.int

  buffer.add(PrefixLUT[styleIdx])

  if isCursor:
    buffer.add(dRepo)
    if dName.len > 0:
      buffer.add(SepSlash)
      buffer.add(dName)
    if dVer.len > 0:
      buffer.add(Space)
      buffer.add(dVer)
  else:
    buffer.add(ColorRepo)
    buffer.add(dRepo)
    buffer.add(Reset)
    if dName.len > 0:
      buffer.add(SepSlash)
      buffer.add(ColorPkg)
      buffer.add(AnsiBold)
      buffer.add(dName)
      buffer.add(Reset)
    if dVer.len > 0:
      buffer.add(Space)
      buffer.add(ColorVer)
      buffer.add(dVer)
      buffer.add(Reset)

  if isInstalled:
    buffer.add(InstalledTag)

  let usedLen =
    PrefixLen + dRepo.len + (if dName.len > 0: 1 + dName.len else: 0) +
    (if dVer.len > 0: 1 + dVer.len else: 0) + tagW
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
        textContent = "Loading..."

    let visLen = visibleWidth(textContent)
    if visLen > detailTextW:
      buffer.add(truncate(textContent, detailTextW))
    else:
      buffer.add(textContent)
      buffer.add(repeat(" ", detailTextW - visLen))
    buffer.add(ColorFrame & BoxVer & Reset)

func renderStatusBar(buffer: var string, state: AppState, termW: int): int =
  let pkgCountStr =
    if state.soa.locators.len == 0:
      fmt"{AnsiDim}(...){AnsiReset}"
    else:
      fmt"{AnsiDim}({state.visibleIndices.len}/{state.soa.locators.len}){AnsiReset}"

  let selCount = state.getSelectedCount()
  let statusPrefix =
    if selCount > 0:
      fmt"{ColorSel}[{selCount}]{AnsiReset} "
    else:
      ""

  var modeStr = ""
  if state.inputMode == ModeVimCommand:
    modeStr = fmt"{ColorVimCommand} COMMAND {AnsiReset}"
  elif state.viewingSelection:
    modeStr = fmt"{ColorModeReview}[Rev]{AnsiReset}"
  elif state.dataSource == SourceNimble:
    modeStr = fmt"{ColorModeNimble}[Nimble]{AnsiReset}"
  elif state.inputMode == ModeVimNormal:
    modeStr = fmt"{ColorVimNormal} NORMAL {AnsiReset}"
  elif state.inputMode == ModeVimInsert:
    modeStr = fmt"{ColorVimInsert} INSERT {AnsiReset}"
  else:
    if state.searchMode == ModeAUR:
      modeStr = fmt"{ColorModeAur}[AUR]{AnsiReset}"
    else:
      modeStr = fmt"{ColorModeLocal}[Local]{AnsiReset}"

  if state.statusMessage.len > 0:
    modeStr.add(fmt" {AnsiBold}{state.statusMessage}{AnsiReset}")

  var leftSide = ""
  var cursorVisualX = 0
  if state.inputMode == ModeVimCommand:
    leftSide = fmt"{ColorPrompt}:{AnsiReset}{state.commandBuffer}"
    cursorVisualX = 1 + visibleWidth(state.commandBuffer)
  else:
    let promptChar = if state.inputMode == ModeVimNormal: ":" else: ">"
    leftSide = fmt"{ColorPrompt}{promptChar}{AnsiReset} {state.searchBuffer}"
    let textBeforeCursor = state.searchBuffer[0 ..< state.searchCursor]
    cursorVisualX = 2 + visibleWidth(textBeforeCursor)

  let leftSideClean =
    if state.inputMode == ModeVimCommand:
      ":" & state.commandBuffer
    else:
      (if state.inputMode == ModeVimNormal: ": " else: "> ") & state.searchBuffer
  let rightSide = fmt"{statusPrefix}{modeStr} {pkgCountStr}"
  let spacing = max(0, termW - visibleWidth(leftSideClean) - visibleWidth(rightSide))

  buffer.add(leftSide)
  buffer.add(repeat(" ", spacing))
  buffer.add(rightSide)
  return cursorVisualX

func renderUi*(state: AppState, buffer: var string, termH, termW: int): RenderResult =
  buffer.setLen(0)
  if termW < MinTermWidth or termH < MinTermHeight:
    buffer.add("\e[2J\e[H" & fmt"{AnsiBold}Terminal size too small.{AnsiReset}")
    return (0, 0)

  let listH = max(1, termH - 2)
  let showDetails = state.showDetails and (termW >= 90)
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
