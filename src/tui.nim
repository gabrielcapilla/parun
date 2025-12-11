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

type RenderResult* = tuple[frame: string, cursorX: int, cursorY: int]

func renderRow(
    state: AppState, idx: int32, width: int, isCursor, isSelected: bool
): string =
  let p = state.pkgs[int(idx)]
  let repo = state.getRepo(p)
  let name = state.getName(p)
  let ver = state.getVersion(p)

  let (cR, cN, cV, cS, rst) =
    if isCursor or isSelected:
      ("", "", "", "", "")
    else:
      (ColorRepo, ColorPkg, ColorVer, ColorState, AnsiReset)

  var content = fmt"{cR}{repo}{rst}/{cN}{AnsiBold}{name}{rst} {cV}{ver}{rst}"

  if p.isInstalled:
    content.add(fmt" {cS}[instalado]{rst}")

  if isSelected:
    content =
      (if isCursor: fmt"{ColorSel}* " else: fmt"{ColorSel}*{AnsiReset} ") & content
  else:
    content = "  " & content

  if isCursor:
    let vLen = visibleWidth(content)
    let pad = max(0, width - vLen)
    result = ColorHighlightBg & content & repeat(" ", pad) & AnsiReset
  else:
    result = content

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

  var buffer = newStringOfCap(termH * termW + 2048)

  for r in 0 ..< listH:
    let idx = state.scroll + (listH - 1 - r)
    var line = ""

    if idx >= 0 and idx < state.visibleIndices.len:
      let realIdx = state.visibleIndices[idx]
      let pId = state.getPkgId(realIdx)
      let isSel = pId in state.selected
      let rowContent = renderRow(state, realIdx, listW, idx == state.cursor, isSel)

      line.add(rowContent)
      let vis = visibleWidth(rowContent)
      if vis < listW:
        line.add(repeat(" ", listW - vis))
    else:
      line.add(repeat(" ", listW))

    if showDetails:
      if r == 0:
        line.add(
          fmt"{ColorFrame}{BoxTopLeft}{repeat(BoxHor, detailTextW)}{BoxTopRight}{AnsiReset}"
        )
      elif r == listH - 1:
        line.add(
          fmt"{ColorFrame}{BoxBottomLeft}{repeat(BoxHor, detailTextW)}{BoxBottomRight}{AnsiReset}"
        )
      else:
        line.add(fmt"{ColorFrame}{BoxVer}{AnsiReset}")
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
              textContent = "Cargando..."

        let visLen = visibleWidth(textContent)
        if visLen > detailTextW:
          line.add(truncate(textContent, detailTextW))
        else:
          line.add(textContent & repeat(" ", detailTextW - visLen))
        line.add(fmt"{ColorFrame}{BoxVer}{AnsiReset}")

    buffer.add(line)
    buffer.add("\n")

  buffer.add(fmt"{ColorFrame}{repeat(BoxHor, termW)}{AnsiReset}")
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
    modeStr = fmt"{ColorModeReview}[REVISIÓN]{AnsiReset}"
  elif state.inputMode == ModeVimNormal:
    modeStr = fmt"{ColorVimNormal} NORMAL {AnsiReset}"
  elif state.inputMode == ModeVimInsert:
    modeStr = fmt"{ColorVimInsert} INSERT {AnsiReset}"
  elif state.searchMode == ModeLocal:
    modeStr = fmt"{ColorModeLocal}[Local]{AnsiReset}"
  else:
    modeStr = fmt"{ColorModeHybrid}[Local+AUR]{AnsiReset}"

  if (state.inputMode == ModeVimNormal or state.inputMode == ModeVimInsert) and
      state.searchMode == ModeHybrid:
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

  let leftSideVisTotal = visibleWidth(leftSide)

  let leftSideClean =
    if state.inputMode == ModeVimCommand:
      ":" & state.commandBuffer
    else:
      (if state.inputMode == ModeVimNormal: ": " else: "> ") & state.searchBuffer
  let leftLen = visibleWidth(leftSideClean)

  let rightSide = fmt"{statusPrefix}{modeStr} {pkgCountStr}"
  let rightLen = visibleWidth(rightSide)

  let spacing = max(0, termW - leftLen - rightLen)

  buffer.add(leftSide & repeat(" ", spacing) & rightSide)

  return (frame: buffer, cursorX: cursorVisualX, cursorY: termH)
