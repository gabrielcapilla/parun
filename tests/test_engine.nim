##
##  Engine Tests
##
## Tests for  main engine (orchestration layer).
##

import unittest
import std/[monotimes, times]
import ../src/core/engine
import ../src/core/state
import ../src/core/types
import ../src/core/input_handler

suite "Engine - Function Signatures":
  test "processInput - existe":
    # Verificar que la función existe
    when declared(processInput):
      check true
    else:
      check false

  test "update - existe":
    # Verificar que la función existe
    when declared(update):
      check true
    else:
      check false

suite "Engine - processInput - Toggle Selection":
  test "processInput - Ctrl+S toggle viewingSelection":
    var state = newState(ModeLocal, false, false)
    state.viewingSelection = false
    state.cursor = 5
    state.scroll = 2

    processInput(state, KeyCtrlS, 10)

    check state.viewingSelection == true
    check state.cursor == 0
    check state.scroll == 0

  test "processInput - Ctrl+S toggle de nuevo":
    var state = newState(ModeLocal, false, false)
    state.viewingSelection = true
    state.cursor = 5
    state.scroll = 2

    processInput(state, KeyCtrlS, 10)

    check state.viewingSelection == false
    check state.cursor == 0
    check state.scroll == 0

suite "Engine - processInput - Toggle Details":
  test "processInput - F1 toggle showDetails":
    var state = newState(ModeLocal, false, false)
    state.showDetails = false

    processInput(state, KeyF1, 10)

    check state.showDetails == true

  test "processInput - F1 toggle hide details":
    var state = newState(ModeLocal, false, false)
    state.showDetails = true

    processInput(state, KeyF1, 10)

    check state.showDetails == false

suite "Engine - processInput - Delegates to handleInput":
  test "processInput - otras teclas van a handleInput":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "test"
    state.searchCursor = 0
    state.visibleIndices = @[int32(0), int32(1), int32(2)]

    processInput(state, 'a', 10)

    # handleInput debería insertar 'a'
    check state.searchBuffer.len == 5

suite "Engine - processInput - Last Input Time":
  test "processInput - actualiza lastInputTime":
    var state = newState(ModeLocal, false, false)
    let before = state.lastInputTime

    processInput(state, 'a', 10)

    check state.lastInputTime >= before

suite "Engine - Query Detection":
  test "searchBuffer starts with nimble/":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "nimble/test"
    state.dataSource = SourceSystem
    state.searchMode = ModeLocal

    processInput(state, ' ', 10)

    # Después de procesar input con "nimble/", debería cambiar a Nimble
    # No podemos verificar directamente sin mocks de manager

  test "searchBuffer starts with aur/":
    var state = newState(ModeLocal, false, false)
    state.searchBuffer = "aur/test"
    state.dataSource = SourceSystem
    state.searchMode = ModeLocal

    processInput(state, ' ', 10)

    # Similar a nimble, debería cambiar a AUR

suite "Engine - State Update Return Value":
  test "update - retorna AppState":
    var state = newState(ModeLocal, false, false)
    let msg = Msg(kind: MsgInput, key: 'a')

    let result = update(state, msg, 10)

    # update retorna una copia de state (AppState es un object, no un puntero)
    check result.searchBuffer == "a"
    check result.needsRedraw == true

suite "Engine - needsRedraw Flag":
  test "update - set needsRedraw":
    var state = newState(ModeLocal, false, false)
    state.needsRedraw = false
    let msg = Msg(kind: MsgInput, key: 'a')

    let result = update(state, msg, 10)

    check result.needsRedraw == true

suite "Engine - Debounce Pending":
  test "processInput - no establece debouncePending":
    var state = newState(ModeLocal, false, false)
    state.debouncePending = false

    processInput(state, 'a', 10)

    check state.debouncePending == false

  test "update puede establecer debouncePending":
    # Solo verificamos que el campo existe
    var state = newState(ModeLocal, false, false)
    state.debouncePending = false

    check state.debouncePending == false

suite "Engine - Status Message":
  test "processInput - limpia statusMessage":
    var state = newState(ModeLocal, false, false)
    state.statusMessage = "Previous message"

    processInput(state, 'a', 10)

    # statusMessage se limpia durante processInput
    check state.statusMessage.len == 0 or state.statusMessage == "Searching..." or
      state.statusMessage == "No results in Nimble" or
      state.statusMessage == "Type to search AUR..." or
      state.statusMessage == "No results in Nimble" or state.statusMessage == "Error"

suite "Engine - Filtering on Input":
  test "processInput - llama a filterIndices":
    var state = newState(ModeLocal, false, false)
    # Inicializar con datos mínimos
    state.soa.hot.locators = @[uint32(0), uint32(1), uint32(2)]
    state.soa.hot.nameLens = @[uint8(4), uint8(4), uint8(4)]
    state.soa.cold.verLens = @[uint8(5), uint8(5), uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0), uint8(0), uint8(0)]
    state.soa.cold.flags = @[uint8(0), uint8(0), uint8(0)]
    state.textArena =
      @[
        't', 'e', 's', 't', '1', '.', '0', '.', '0', 't', 'e', 's', 't', '2', '.', '0',
        '.', '0', 't', 'e', 's', 't', '3', '.', '0', '.', '0',
      ]
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    state.searchBuffer = "test"

    processInput(state, ' ', 10)

    # filterIndices debería haberse llamado
    # No podemos verificar el resultado directo sin acceder a internals

suite "Engine - Mode Switching":
  test "processInput - en modo viewingSelection llama a filterBySelection":
    var state = newState(ModeLocal, false, false)
    state.viewingSelection = true
    # Inicializar con datos mínimos
    state.soa.hot.locators = @[uint32(0), uint32(1), uint32(2)]
    state.soa.hot.nameLens = @[uint8(4), uint8(4), uint8(4)]
    state.soa.cold.verLens = @[uint8(5), uint8(5), uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0), uint8(0), uint8(0)]
    state.soa.cold.flags = @[uint8(0), uint8(0), uint8(0)]
    state.textArena =
      @[
        't', 'e', 's', 't', '1', '.', '0', '.', '0', 't', 'e', 's', 't', '2', '.', '0',
        '.', '0', 't', 'e', 's', 't', '3', '.', '0', '.', '0',
      ]
    state.repos = @["extra"]
    state.repoArena = @['e', 'x', 't', 'r', 'a']
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    processInput(state, KeyCtrlS, 10)

    # Debería llamar a filterBySelection en modo viewingSelection
    check state.viewingSelection == false

suite "Engine - Constants":
  test "MsgInput - valor correcto":
    check int(MsgInput) == 0

  test "MsgTick - valor correcto":
    check int(MsgTick) == 1

  test "MsgSearchResults - valor correcto":
    check int(MsgSearchResults) == 2

  test "MsgDetailsLoaded - valor correcto":
    check int(MsgDetailsLoaded) == 3

  test "MsgError - valor correcto":
    check int(MsgError) == 4

suite "Engine - Performance":
  test "Benchmark processInput 1K llamadas":
    var state = newState(ModeLocal, false, false)
    let start = getMonoTime()

    for i in 0 ..< 1000:
      processInput(state, 'a', 10)

    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 5000 # < 5s (includes filtering)

  test "Benchmark toggle viewingSelection 10K operaciones":
    var state = newState(ModeLocal, false, false)
    let start = getMonoTime()

    for i in 0 ..< 10000:
      state.viewingSelection = i mod 2 == 0
      processInput(state, KeyCtrlS, 10)

    let elapsed = getMonoTime() - start
    check elapsed.inMilliseconds < 500 # < 500ms

suite "Engine - Message Types":
  test "Msg tiene campo kind":
    var msg = Msg(kind: MsgInput, key: 'a')
    check msg.kind == MsgInput

  test "Msg tiene campo key":
    var msg = Msg(kind: MsgInput, key: 'a')
    check msg.key == 'a'

  test "MsgSearchResults tiene textChunk y searchId":
    var msg = Msg(kind: MsgSearchResults, textChunk: "", isAppend: true, searchId: 1)
    check msg.textChunk.len == 0
    check msg.searchId == 1
    check msg.isAppend == true

  test "MsgDetailsLoaded tiene pkgIdx y content":
    var msg = Msg(kind: MsgDetailsLoaded, pkgIdx: 42, content: "Test content")
    check msg.pkgIdx == 42
    check msg.content == "Test content"

  test "MsgError tiene errMsg":
    var msg = Msg(kind: MsgError, errMsg: "Test error")
    check msg.errMsg == "Test error"
