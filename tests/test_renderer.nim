##
##  Renderer Tests
##
## Tests for UI rendering components.
##

import unittest
import std/[strutils, strformat, monotimes, times]
import ../src/ui/renderer
import ../src/core/types
import ../src/core/state
import ../src/utils/utils

suite "Renderer - Constants":
  test "MinTermWidth - valor correcto":
    check MinTermWidth == 50

  test "MinTermHeight - valor correcto":
    check MinTermHeight == 10

  test "Box characters - definidos":
    check BoxTopLeft == "╭"
    check BoxTopRight == "╮"
    check BoxBottomLeft == "╰"
    check BoxBottomRight == "╯"
    check BoxHor == "─"
    check BoxVer == "│"

  test "Color constants - definidos":
    check ColorFrame == "\e[90m"
    check Reset == "\e[0m"

  test "PrefixLUT - tiene 4 entradas":
    check PrefixLUT.len == 4
    check PrefixLUT[0] == "  " # No cursor, no selected
    check PrefixLUT[1].contains("*") # No cursor, selected
    check PrefixLUT[2].contains("\e[48;5;235m") # Cursor, no selected
    check PrefixLUT[3].contains("\e[48;5;235m") # Cursor, selected

  test "Length constants - definidas":
    check PrefixLen == 2
    check InstalledLen == 12
    check Spaces50.len == 50

suite "Renderer - StatusBar":
  test "renderStatusBar - width 100":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check buffer.len > 0
    check buffer.startsWith(ColorPrompt)
    check buffer.endsWith(Reset)
    check cursorX >= 2
    check cursorX <= 100

  test "renderStatusBar - width 50 (minimo)":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 50)

    check buffer.len > 0
    check cursorX >= 2
    check cursorX <= 50

  test "renderStatusBar - con search buffer":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    state.searchCursor = 4
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check buffer.contains("test")
    check cursorX >= 2 + visibleWidth("test")

  test "renderStatusBar - con packages seleccionados":
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[int32(0), int32(1), int32(2)]
    state.toggleSelection(int(0))
    state.toggleSelection(int(1))
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("[2]") # 2 seleccionados

  test "renderStatusBar - modo viewingSelection":
    var state = newState(ModeLocal, false, false)
    state.viewingSelection = true
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("[Rev]")

  test "renderStatusBar - modo Nimble":
    var state = newState(ModeLocal, false, true)
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("[Nimble]")

  test "renderStatusBar - modo AUR":
    var state = newState(ModeAUR, false, false)
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("[Aur]")

  test "renderStatusBar - modo Local":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("[Local]")

  test "renderStatusBar - con status message":
    var state = newState(ModeLocal, false, false)
    state.statusMessage = "Loading..."
    var buffer = ""
    discard renderStatusBar(buffer, state, 100)

    check buffer.contains("Loading...")

  test "renderStatusBar - cursor position correcto":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    state.searchCursor = 2 # Cursor en 's'
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check cursorX == 2 + 2 # '> ' + 'te'
    discard cursorX # Evitar warning

  test "renderStatusBar - cursor al inicio":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    state.searchCursor = 0
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check cursorX == 2 # '> '

  test "renderStatusBar - cursor al final":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    state.searchCursor = 4
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check cursorX == 2 + visibleWidth("test")

suite "Renderer - Details Panel":
  test "renderDetails - fila superior (box top)":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    renderDetails(buffer, state, 0, 10, 50)

    check buffer.contains(BoxTopLeft)
    check buffer.contains(BoxTopRight)
    check buffer.contains(BoxHor)

  test "renderDetails - fila inferior (box bottom)":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    renderDetails(buffer, state, 9, 10, 50)

    check buffer.contains(BoxBottomLeft)
    check buffer.contains(BoxBottomRight)
    check buffer.contains(BoxHor)

  test "renderDetails - fila del medio (box sides)":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    renderDetails(buffer, state, 5, 10, 50)

    check buffer.contains(BoxVer)
    check buffer.contains(ColorFrame)

  test "renderDetails - sin paquetes visibles":
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[]
    var buffer = ""
    renderDetails(buffer, state, 1, 10, 50)

    check buffer.contains(BoxVer)

  test "renderDetails - con cache vacio":
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[int32(0)]
    var buffer = ""
    renderDetails(buffer, state, 1, 10, 50)

    check buffer.contains("...")

  test "renderDetails - truncamiento de linea larga":
    var state = newState(ModeLocal, false, false)
    state.visibleIndices = @[int32(0)]
    var buffer = ""
    renderDetails(buffer, state, 1, 10, 20)

    check buffer.len >= 4 # Al menos 4 caracteres de box
    check buffer.contains("...") # No hay cache, muestra "..."

suite "Renderer - Append Row":
  test "appendRow - con cursor y sin seleccion":
    var state = newState(ModeLocal, false, false)
    # Inicializar con datos minimos
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.textArena =
      @['t', 'e', 's', 't', '1', '.', '0', '.', '0', 'e', 'x', 't', 'r', 'a']
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buffer = ""
    appendRow(buffer, state, int32(0), 80, true, false)

    check buffer.len > 0
    check buffer.contains(PrefixLUT[2]) # Cursor sin seleccion

  test "appendRow - sin cursor y con seleccion":
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.textArena =
      @['t', 'e', 's', 't', '1', '.', '0', '.', '0', 'e', 'x', 't', 'r', 'a']
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buffer = ""
    appendRow(buffer, state, int32(0), 80, false, true)

    check buffer.contains(PrefixLUT[1]) # Seleccionado sin cursor

  test "appendRow - con ambos (cursor y seleccion)":
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.textArena =
      @['t', 'e', 's', 't', '1', '.', '0', '.', '0', 'e', 'x', 't', 'r', 'a']
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buffer = ""
    appendRow(buffer, state, int32(0), 80, true, true)

    check buffer.contains(PrefixLUT[3]) # Ambos

  test "appendRow - sin nada":
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.textArena =
      @['t', 'e', 's', 't', '1', '.', '0', '.', '0', 'e', 'x', 't', 'r', 'a']
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buffer = ""
    appendRow(buffer, state, int32(0), 80, false, false)

    check buffer.contains(PrefixLUT[0]) # Normal

suite "Renderer - Edge Cases":
  test "renderStatusBar - width muy pequeno (50)":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "very long search string that exceeds width"
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 50)

    check buffer.len <= 50 + 50
      # ANSI codes no cuentan para len, pero pueden exceder width

  test "renderStatusBar - buffer vacio":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = ""
    state.searchCursor = 0
    var buffer = ""
    let cursorX = renderStatusBar(buffer, state, 100)

    check cursorX == 2 # '> '
    check buffer.contains(">")

  test "renderDetails - detailTextW = 0":
    var state = newState(ModeLocal, false, false)
    var buffer = ""
    renderDetails(buffer, state, 1, 10, 0)

    check buffer.len > 0 # Debería tener al menos los caracteres de box

  test "renderDetails - listHeight = 1 (solo top y bottom)":
    var state = newState(ModeLocal, false, false)
    var buffer1 = ""
    var buffer2 = ""
    renderDetails(buffer1, state, 0, 1, 50)
    renderDetails(buffer2, state, 0, 1, 50)

    check buffer1.contains(BoxTopLeft)
    check buffer1.contains(BoxTopRight)
    # Ambas llamadas con r=0 deberían mostrar lo mismo (top)

  test "PrefixLUT indices correctos":
    # 0: no cursor, no selected
    check PrefixLUT[0] == "  "
    # 1: no cursor, selected
    check PrefixLUT[1].contains("*")
    check not PrefixLUT[1].contains("\e[48;5;235m")
    # 2: cursor, no selected
    check PrefixLUT[2].contains("\e[48;5;235m")
    check not PrefixLUT[2].contains("*")
    # 3: cursor, selected
    check PrefixLUT[3].contains("\e[48;5;235m")
    check PrefixLUT[3].contains("*")

suite "Renderer - Performance":
  test "Benchmark renderStatusBar 1K operaciones":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    var buffer = ""

    let start = getMonoTime()
    for i in 0 ..< 1000:
      buffer.setLen(0)
      discard renderStatusBar(buffer, state, 100)
    let elapsed = getMonoTime() - start

    check elapsed.inNanoseconds div 1_000_000 < 100 # < 100ms

  test "Benchmark renderDetails 1K filas":
    var state = newState(ModeLocal, false, false)
    var buffer = ""

    let start = getMonoTime()
    for i in 0 ..< 1000:
      buffer.setLen(0)
      renderDetails(buffer, state, i mod 10, 10, 50)
    let elapsed = getMonoTime() - start

    check elapsed.inNanoseconds div 1_000_000 < 100 # < 100ms

  test "Benchmark PrefixLUT access 10K operaciones":
    let start = getMonoTime()
    for i in 0 ..< 10000:
      let idx = i mod 4
      let prefix = PrefixLUT[idx]
      discard prefix.len
    let elapsed = getMonoTime() - start

    check elapsed.inNanoseconds div 1_000_000 < 10 # < 10ms (array access is fast)

  test "Benchmark appendRow 10K filas":
    var state = newState(ModeLocal, false, false)
    # Inicializar con datos minimos
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(4)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.textArena =
      @['t', 'e', 's', 't', '1', '.', '0', '.', '0', 'e', 'x', 't', 'r', 'a']
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buffer = ""

    let start = getMonoTime()
    for i in 0 ..< 10000:
      buffer.setLen(0)
      appendRow(buffer, state, int32(0), 80, i mod 2 == 0, i mod 3 == 0)
    let elapsed = getMonoTime() - start

    check elapsed.inNanoseconds div 1_000_000 < 500 # < 500ms
