import std/[strformat, strutils, sets, tables]
import types, utils, core

const
  BoxTopLeft = "╭"
  BoxTopRight = "╮"
  BoxBottomLeft = "╰"
  BoxBottomRight = "╯"
  BoxHor = "─"
  BoxVer = "│"
  ColorFrame = "\e[90m"

  Reset = "\e[0m"
  CursorPrefixSel = "\e[93m* "
  CursorPrefixUnsel = "\e[93m*\e[0m "
  NormalPrefix = "  "
  SepSlash = "/"
  Space = " "
  InstalledTag = " \e[36m[installed]\e[0m"

  Spaces50 = "                                                  "

type RenderResult* = tuple[frame: string, cursorX: int, cursorY: int]

func appendRow(
    buffer: var string,
    state: AppState,
    idx: int32,
    width: int,
    isCursor, isSelected: bool,
) =
  let p = state.pkgs[int(idx)]

  if isCursor:
    buffer.add(ColorHighlightBg)

  if isSelected:
    if isCursor:
      buffer.add(CursorPrefixSel)
    else:
      buffer.add(CursorPrefixUnsel)
  else:
    buffer.add(NormalPrefix)

  if isCursor or isSelected:
    buffer.add(state.getRepo(p))
    buffer.add(SepSlash)
    buffer.add(state.getName(p))
    buffer.add(Space)
    buffer.add(state.getVersion(p))
  else:
    buffer.add(ColorRepo)
    buffer.add(state.getRepo(p))
    buffer.add(Reset)
    buffer.add(SepSlash)
    buffer.add(ColorPkg)
    buffer.add(AnsiBold)
    buffer.add(state.getName(p))
    buffer.add(Reset)
    buffer.add(Space)
    buffer.add(ColorVer)
    buffer.add(state.getVersion(p))
    buffer.add(Reset)

  if p.isInstalled:
    buffer.add(InstalledTag)

  if isCursor:
    let contentStr =
      (if isSelected: "* " else: "  ") & state.getRepo(p) & "/" & state.getName(p) & " " &
      state.getVersion(p) & (if p.isInstalled: " [installed]" else: "")

    let vLen = contentStr.len
    let pad = max(0, width - vLen)

    if pad > 0:
      var p = pad
      while p >= 50:
        buffer.add(Spaces50)
        p -= 50
      if p > 0:
        buffer.add(Spaces50[0 ..< p])

    buffer.add(Reset)
  else:
    let contentStr =
      (if isSelected: "* " else: "  ") & state.getRepo(p) & "/" & state.getName(p) & " " &
      state.getVersion(p) & (if p.isInstalled: " [installed]" else: "")

    let vLen = contentStr.len
    if vLen < width:
      buffer.add(repeat(" ", width - vLen))

func renderUi*(state: AppState, termH, termW: int): RenderResult =
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

  var buffer = newStringOfCap(termH * termW + 4096)

  for r in 0 ..< listH:
    let idx = state.scroll + (listH - 1 - r)

    if idx >= 0 and idx < state.visibleIndices.len:
      let realIdx = state.visibleIndices[idx]
      let pId = state.getPkgId(realIdx)
      let isSel = pId in state.selected

      appendRow(buffer, state, realIdx, listW, idx == state.cursor, isSel)
    else:
      buffer.add(repeat(" ", listW))

    if showDetails:
      if r == 0:
        buffer.add(ColorFrame)
        buffer.add(BoxTopLeft)
        buffer.add(repeat(BoxHor, detailTextW))
        buffer.add(BoxTopRight)
        buffer.add(Reset)
      elif r == listH - 1:
        buffer.add(ColorFrame)
        buffer.add(BoxBottomLeft)
        buffer.add(repeat(BoxHor, detailTextW))
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
          let pId = state.getPkgId(curIdx)
          if state.detailsCache.hasKey(pId):
            let dLines = state.detailsCache[pId].splitLines
            let scrollOffset = state.detailScroll
            let effectiveDetailIdx = contentRowIndex + scrollOffset
            if effectiveDetailIdx < dLines.len:
              textContent = dLines[effectiveDetailIdx].replace("\t", "  ")
          else:
            if contentRowIndex == 0:
              textContent = "Loading..."

        let visLen = visibleWidth(textContent)
        if visLen > detailTextW:
          buffer.add(truncate(textContent, detailTextW))
        else:
          buffer.add(textContent)
          buffer.add(repeat(" ", detailTextW - visLen))

        buffer.add(ColorFrame)
        buffer.add(BoxVer)
        buffer.add(Reset)

    buffer.add("\n")

  buffer.add(ColorFrame)
  buffer.add(repeat(BoxHor, termW))
  buffer.add(Reset)
  buffer.add("\n")

  let pkgCountStr =
    if state.pkgs.len == 0:
      fmt"{AnsiDim}(...){AnsiReset}"
    else:
      fmt"{AnsiDim}({state.visibleIndices.len}/{state.pkgs.len}){AnsiReset}"

  var statusPrefix = ""
  if state.selected.len > 0:
    statusPrefix.add(fmt"{ColorSel}[{state.selected.len}]{AnsiReset} ")

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
  elif state.searchMode == ModeLocal:
    modeStr = fmt"{ColorModeLocal}[Local]{AnsiReset}"
  else:
    modeStr = fmt"{ColorModeHybrid}[Local+AUR]{AnsiReset}"

  if (state.inputMode == ModeVimNormal or state.inputMode == ModeVimInsert) and
      state.searchMode == ModeHybrid and state.dataSource == SourceSystem:
    modeStr.add(fmt" {ColorModeHybrid}[AUR]{AnsiReset}")

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
  let leftLen = visibleWidth(leftSideClean)

  let rightSide = fmt"{statusPrefix}{modeStr} {pkgCountStr}"
  let rightLen = visibleWidth(rightSide)

  let spacing = max(0, termW - leftLen - rightLen)

  buffer.add(leftSide)
  buffer.add(repeat(" ", spacing))
  buffer.add(rightSide)

  return (frame: buffer, cursorX: cursorVisualX, cursorY: termH)
