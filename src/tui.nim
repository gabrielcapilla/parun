import std/[strformat, strutils, sets, tables]
import types, utils, core

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
  let listH = max(1, termH - 1)
  let showDetails = state.showDetails and (termW >= 90)
  let listW =
    if showDetails:
      termW div 2
    else:
      termW
  let detailW =
    if showDetails:
      termW - listW - 1
    else:
      0

  var buffer = newStringOfCap(termH * termW + 1024)

  for r in 0 ..< listH:
    let idx = state.scroll + (listH - 1 - r)

    var line = ""
    if idx >= 0 and idx < state.visibleIndices.len:
      let realIdx = state.visibleIndices[idx]
      let pId = state.getPkgId(realIdx)
      let isSel = pId in state.selected

      line = renderRow(state, realIdx, listW, idx == state.cursor, isSel)

      let vis = visibleWidth(line)
      if vis < listW:
        line.add(repeat(" ", listW - vis))
    else:
      line = repeat(" ", listW)

    if showDetails:
      line.add(fmt"{ColorPrompt}│{AnsiReset}")
      if state.visibleIndices.len > 0:
        let curIdx = state.visibleIndices[state.cursor]
        let pId = state.getPkgId(curIdx)
        if state.detailsCache.hasKey(pId):
          let dLines = state.detailsCache[pId].splitLines

          let scrollOffset = state.detailScroll
          let effectiveR = r + scrollOffset

          if effectiveR < dLines.len:
            let dLine = dLines[effectiveR]
            let cleanLine = dLine.replace("\t", "  ")

            if cleanLine.len > detailW:
              line.add(truncate(cleanLine, detailW))
            else:
              line.add(cleanLine & repeat(" ", detailW - cleanLine.len))
          else:
            line.add(repeat(" ", detailW))
        else:
          if r == 0:
            line.add("...")
          else:
            line.add(repeat(" ", detailW))
      else:
        line.add(repeat(" ", detailW))

    buffer.add(line & "\n")

  let pkgCountStr =
    if state.pkgs.len == 0:
      fmt"{AnsiDim}(...){AnsiReset}"
    else:
      fmt"{AnsiDim}({state.visibleIndices.len}/{state.pkgs.len}){AnsiReset}"

  var statusPrefix = ""
  if state.selected.len > 0:
    statusPrefix.add(fmt"{ColorSel}[{state.selected.len}]{AnsiReset} ")

  let modeStr =
    if state.searchMode == ModeLocal:
      fmt"{ColorModeLocal}[Local]{AnsiReset}"
    else:
      fmt"{ColorModeHybrid}[Local+AUR]{AnsiReset}"

  var displayBuffer = state.searchBuffer
  if state.searchCursor >= 0 and state.searchCursor <= state.searchBuffer.len:
    displayBuffer.insert("_", state.searchCursor)

  let leftSide = fmt"{ColorPrompt}>{AnsiReset} {displayBuffer}"
  let leftLen = visibleWidth(leftSide)
  let rightSide = fmt"{statusPrefix}{modeStr} {pkgCountStr}"
  let rightLen = visibleWidth(rightSide)

  let spacing = max(0, termW - leftLen - rightLen)
  let statusLine = leftSide & repeat(" ", spacing) & rightSide

  let promptVisLen = 2
  let cursorVisualX = promptVisLen

  buffer.add(statusLine)

  return (frame: buffer, cursorX: cursorVisualX, cursorY: termH)
