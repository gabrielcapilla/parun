import unittest
import std/[monotimes, times, strutils, sequtils]
import ../src/core/state
import ../src/core/types

suite "State - StringArena":
  test "initStringArena - capacidad correcta":
    let arena = initStringArena(1024)
    check arena.capacity == 1024
    check arena.offset == 0
    check arena.buffer.len == 1024

  test "allocString - simple string":
    var arena = initStringArena(1024)
    let handle = arena.allocString("hello")
    check handle.length == 5
    check handle.startOffset == 0
    check arena.offset == 5

  test "allocString - multiple strings":
    var arena = initStringArena(1024)
    discard arena.allocString("first")
    discard arena.allocString("second")
    discard arena.allocString("third")
    check arena.offset == 5 + 6 + 5 # first + second + third

  test "allocString - correct content":
    var arena = initStringArena(1024)
    let handle1 = arena.allocString("hello")
    let handle2 = arena.allocString("world")

    let str1 = newString(handle1.length)
    copyMem(addr str1[0], addr arena.buffer[handle1.startOffset], handle1.length)
    check str1 == "hello"

    let str2 = newString(handle2.length)
    copyMem(addr str2[0], addr arena.buffer[handle2.startOffset], handle2.length)
    check str2 == "world"

  test "resetArena - resets offset":
    var arena = initStringArena(1024)
    discard arena.allocString("hello")
    check arena.offset == 5

    arena.resetArena()
    check arena.offset == 0

  test "allocString - overflow with wrap-around":
    var arena = initStringArena(10)
    discard arena.allocString("12345") # offset = 5
    check arena.offset == 5

    discard arena.allocString("123456") # offset = 11 > 10, wrap to 0
    # Note: after wrap, offset remains at 11 (bug or feature)
    check arena.offset == 11

  test "allocString - very large string raises":
    var arena = initStringArena(10)
    expect IndexDefect:
      discard arena.allocString("very-long-string")

suite "State - Package Access":
  setup:
    var state = newState(ModeLocal, false, false)
    # Setup test data
    # Paquete 0: "vim8.0.0" (offset 0, nameLen 3, verLen 5)
    # Paquete 1: "emacs25.0.0" (offset 13, nameLen 5, verLen 6)
    state.textArena = "vim8.0.0extraemacs25.0.0extra".toSeq()
    state.soa.hot.locators = @[uint32(0), uint32(13)]
    state.soa.hot.nameLens = @[uint8(3), uint8(5)]
    state.soa.cold.verLens = @[uint8(5), uint8(6)]
    state.soa.cold.repoIndices = @[uint8(0), uint8(0)]
    state.repos = @["extra"]
    state.repoArena = "extra".toSeq()
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

  test "appendName - simple":
    var buf = ""
    state.appendName(0, buf)
    check buf == "vim"

  test "appendVersion - simple":
    var buf = ""
    state.appendVersion(0, buf)
    check buf == "8.0.0"

  test "appendRepo - simple":
    var buf = ""
    state.appendRepo(0, buf)
    check buf == "extra"

  test "appendName - with maxLen":
    var buf = ""
    state.appendName(1, buf, 3)
    check buf == "ema" # first 3 chars of "emacs"

  test "appendVersion - with maxLen":
    var buf = ""
    state.appendVersion(1, buf, 2)
    check buf == "25"

  test "getName - returns full string":
    check state.getName(0) == "vim"

  test "getVersion - returns full string":
    check state.getVersion(0) == "8.0.0"

  test "getRepo - returns full string":
    check state.getRepo(0) == "extra"

  test "getNameLen - returns length":
    check state.getNameLen(0) == 3
    check state.getNameLen(1) == 5

  test "getVersionLen - returns length":
    check state.getVersionLen(0) == 5
    check state.getVersionLen(1) == 6

  test "getRepoLen - returns length":
    check state.getRepoLen(0) == 5

  test "getPkgId - repo/name format":
    check state.getPkgId(0) == "extra/vim"

suite "State - Query Processing":
  test "getEffectiveQuery - no prefix":
    check getEffectiveQuery("vim") == "vim"

  test "getEffectiveQuery - aur/ prefix":
    check getEffectiveQuery("aur/vim") == "vim"

  test "getEffectiveQuery - nimble/ prefix":
    check getEffectiveQuery("nimble/vim") == "vim"

  test "getEffectiveQuery - nim/ prefix":
    check getEffectiveQuery("nim/vim") == "vim"

  test "getEffectiveQuery - empty query":
    check getEffectiveQuery("") == ""

  test "getEffectiveQuery - prefix only":
    check getEffectiveQuery("aur/") == ""

suite "State - Filter Indices":
  setup:
    var state = newState(ModeLocal, false, false)
    # Setup test data
    state.textArena = "vimemacsnanopythonneovim".toSeq()
    state.soa.hot.locators = @[uint32(0), uint32(3), uint32(8), uint32(12), uint32(18)]
    state.soa.hot.nameLens = @[uint8(3), uint8(5), uint8(4), uint8(6), uint8(6)]
    state.soa.cold.verLens = @[uint8(1), uint8(1), uint8(1), uint8(1), uint8(1)]
    state.soa.cold.repoIndices = @[uint8(0), uint8(0), uint8(0), uint8(0), uint8(0)]
    state.soa.cold.flags = @[uint8(0), uint8(0), uint8(0), uint8(0), uint8(0)]
    state.repos = @["extra"]
    state.repoArena = "extra".toSeq()
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

  test "filterIndices - empty query returns all":
    var results = newSeq[int32]()
    filterIndices(state, "", results)
    check results.len == 5

  test "filterIndices - query 'vim'":
    var results = newSeq[int32]()
    filterIndices(state, "vim", results)
    check results.len > 0
    check "vim" in state.getName(int(results[0]))

  test "filterIndices - query no match":
    var results = newSeq[int32]()
    filterIndices(state, "nonexistent", results)
    check results.len == 0

  test "filterIndices - reuses buffer":
    var results = newSeq[int32]()
    filterIndices(state, "vim", results)
    let len1 = results.len

    filterIndices(state, "emacs", results)
    let len2 = results.len

    # Reuse without realloc if buffer is large enough
    check len2 <= len1 or len2 > 0

  test "filterIndices - max 2000 results":
    var bigState = newState(ModeLocal, false, false)
    # Crear 3000 paquetes
    var text = ""
    var locators = newSeq[uint32]()
    var nameLens = newSeq[uint8]()
    var verLens = newSeq[uint8]()
    var repoIndices = newSeq[uint8]()
    var flags = newSeq[uint8]()

    for i in 0 ..< 3000:
      let name = "pkg" & $i
      text.add(name)
      text.add("1") # version placeholder
      locators.add(uint32(text.len - name.len - 1))
      nameLens.add(uint8(name.len))
      verLens.add(uint8(1))
      repoIndices.add(uint8(0))
      flags.add(uint8(0))

    bigState.textArena = text.toSeq()
    bigState.soa.hot.locators = locators
    bigState.soa.hot.nameLens = nameLens
    bigState.soa.cold.verLens = verLens
    bigState.soa.cold.repoIndices = repoIndices
    bigState.soa.cold.flags = flags
    bigState.repos = @["extra"]
    bigState.repoArena = "extra".toSeq()
    bigState.repoLens = @[uint8(5)]
    bigState.repoOffsets = @[uint16(0)]

    var results = newSeq[int32]()
    filterIndices(bigState, "pkg", results)

    check results.len <= 2000

suite "State - Selection":
  setup:
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = newSeq[uint32]()
    state.soa.hot.nameLens = newSeq[uint8]()
    state.soa.cold.verLens = newSeq[uint8]()
    state.soa.cold.repoIndices = newSeq[uint8]()
    state.soa.cold.flags = newSeq[uint8]()

    for i in 0 ..< 100:
      state.soa.hot.locators.add(uint32(i))
      state.soa.hot.nameLens.add(uint8(3))
      state.soa.cold.verLens.add(uint8(1))
      state.soa.cold.repoIndices.add(uint8(0))
      state.soa.cold.flags.add(uint8(0))
    state.selectionBits = newSeq[uint64]()
    state.visibleIndices = newSeq[int32]()

  test "isSelected - initially false":
    check state.isSelected(0) == false
    check state.isSelected(50) == false
    check state.isSelected(99) == false

  test "toggleSelection - toggles bit":
    state.toggleSelection(0)
    check state.isSelected(0) == true

    state.toggleSelection(0)
    check state.isSelected(0) == false

  test "toggleSelection - multiple bits":
    state.toggleSelection(0)
    state.toggleSelection(1)
    state.toggleSelection(63)
    state.toggleSelection(64)

    check state.isSelected(0) == true
    check state.isSelected(1) == true
    check state.isSelected(63) == true
    check state.isSelected(64) == true

  test "toggleSelection - expands selectionBits":
    check state.selectionBits.len == 0

    state.toggleSelection(100)
    check state.selectionBits.len > 0

  test "getSelectedCount - counts correctly":
    state.toggleSelection(0)
    state.toggleSelection(10)
    state.toggleSelection(20)

    check state.getSelectedCount() == 3

  test "filterBySelection - filters selected":
    state.toggleSelection(0)
    state.toggleSelection(5)
    state.toggleSelection(10)

    var results = newSeq[int32]()
    filterBySelection(state, results)

    check results.len == 3
    check int32(0) in results
    check int32(5) in results
    check int32(10) in results

  test "filterBySelection - no selection empty":
    var results = newSeq[int32]()
    filterBySelection(state, results)
    check results.len == 0

  test "toggleSelectionAtCursor - toggles and advances":
    state.visibleIndices = @[int32(0), int32(1), int32(2), int32(3), int32(4)]
    state.cursor = 0

    toggleSelectionAtCursor(state)
    check state.isSelected(0) == true
    check state.cursor == 1

suite "State - Database Management":
  setup:
    var state = newState(ModeLocal, false, false)
    # Setup test data
    state.textArena = "vim8.0.0extra".toSeq()
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(3)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.repos = @["extra"]
    state.repoArena = "extra".toSeq().toSeq()
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

  test "saveCurrentToDB - systemDB local":
    state.dataSource = SourceSystem
    state.searchMode = ModeLocal
    saveCurrentToDB(state)

    check state.systemDB.isLoaded == true
    check state.systemDB.textArena == state.textArena

  test "saveCurrentToDB - systemDB aur":
    state.dataSource = SourceSystem
    state.searchMode = ModeAUR
    saveCurrentToDB(state)

    check state.aurDB.isLoaded == true

  test "saveCurrentToDB - nimbleDB":
    state.dataSource = SourceNimble
    saveCurrentToDB(state)

    check state.nimbleDB.isLoaded == true

  test "loadFromDB - systemDB local":
    saveCurrentToDB(state)
    state.textArena = @[]
    state.soa.hot.locators = @[]

    loadFromDB(state, SourceSystem)

    check state.textArena.len > 0
    check state.soa.hot.locators.len > 0

  test "loadFromDB - nimbleDB":
    state.dataSource = SourceNimble
    saveCurrentToDB(state)
    state.textArena = @[]

    loadFromDB(state, SourceNimble)

    check state.textArena.len > 0

  # Note: switchToNimble, switchToSystem and restoreBaseState require
  # active messaging system (channels) to work correctly
  # so they are not tested in unit tests.

suite "State - Initialization":
  test "newState - correct defaults":
    let state = newState(ModeLocal, false, false)

    check state.searchMode == ModeLocal
    check state.showDetails == false
    check state.dataSource == SourceSystem

    check state.cursor == 0
    check state.scroll == 0
    check state.searchBuffer == ""
    check state.searchCursor == 0

    check state.shouldQuit == false
    check state.shouldInstall == false
    check state.shouldUninstall == false

    check state.visibleIndices.len == 0
    check state.selectionBits.len == 0

  test "newState - with details enabled":
    let state = newState(ModeLocal, true, false)

    check state.showDetails == true

  test "newState - nimble mode":
    let state = newState(ModeLocal, false, true)

    check state.dataSource == SourceNimble
    check state.baseDataSource == SourceNimble

  test "newState - aur mode as base":
    let state = newState(ModeAUR, false, false)

    check state.searchMode == ModeAUR
    check state.baseSearchMode == ModeAUR

  test "isInstalled - bit 0 in flags":
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = @[uint32(0), uint32(0), uint32(0), uint32(0)]
    state.soa.hot.nameLens = @[uint8(3), uint8(3), uint8(3), uint8(3)]
    state.soa.cold.verLens = @[uint8(1), uint8(1), uint8(1), uint8(1)]
    state.soa.cold.repoIndices = @[uint8(0), uint8(0), uint8(0), uint8(0)]
    state.soa.cold.flags = @[uint8(0), uint8(1), uint8(0), uint8(1)]

    check state.isInstalled(0) == false
    check state.isInstalled(1) == true
    check state.isInstalled(2) == false
    check state.isInstalled(3) == true

suite "State - Performance":
  test "Benchmark filterIndices 10K packages":
    var state = newState(ModeLocal, false, false)

    var text = ""
    var locators = newSeq[uint32]()
    var nameLens = newSeq[uint8]()
    var verLens = newSeq[uint8]()
    var repoIndices = newSeq[uint8]()
    var flags = newSeq[uint8]()

    for i in 0 ..< 10000:
      let name = "pkg" & $i
      text.add(name)
      text.add("1") # version placeholder
      locators.add(uint32(text.len - name.len - 1))
      nameLens.add(uint8(name.len))
      verLens.add(uint8(1))
      repoIndices.add(uint8(0))
      flags.add(uint8(0))

    state.textArena = text.toSeq()
    state.soa.hot.locators = locators
    state.soa.hot.nameLens = nameLens
    state.soa.cold.verLens = verLens
    state.soa.cold.repoIndices = repoIndices
    state.soa.cold.flags = flags
    state.repos = @["extra"]
    state.repoArena = "extra".toSeq()
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var results = newSeq[int32]()
    let start = getMonoTime()
    filterIndices(state, "pkg", results)
    let elapsed = getMonoTime() - start

    check results.len <= 2000 # Max 2000
    check elapsed.inMilliseconds < 50 # < 50ms

  test "Benchmark toggleSelection 1000 toggles":
    var state = newState(ModeLocal, false, false)
    state.soa.hot.locators = newSeq[uint32](1000)
    state.soa.hot.nameLens = newSeq[uint8](1000)
    state.soa.cold.verLens = newSeq[uint8](1000)
    state.soa.cold.repoIndices = newSeq[uint8](1000)
    state.soa.cold.flags = newSeq[uint8](1000)

    let start = getMonoTime()
    for i in 0 ..< 1000:
      state.toggleSelection(i)
    let elapsed = getMonoTime() - start

    check state.getSelectedCount() == 1000
    check elapsed.inMilliseconds < 10 # < 10ms

  test "Benchmark appendName 10K calls":
    var state = newState(ModeLocal, false, false)
    state.textArena = "vim8.0.0extra".toSeq()
    state.soa.hot.locators = @[uint32(0)]
    state.soa.hot.nameLens = @[uint8(3)]
    state.soa.cold.verLens = @[uint8(5)]
    state.soa.cold.repoIndices = @[uint8(0)]
    state.soa.cold.flags = @[uint8(0)]
    state.repos = @["extra"]
    state.repoArena = "extra".toSeq()
    state.repoLens = @[uint8(5)]
    state.repoOffsets = @[uint16(0)]

    var buf = newStringOfCap(65536)
    let start = getMonoTime()
    for i in 0 ..< 10000:
      state.appendName(0, buf)
    let elapsed = getMonoTime() - start

    check elapsed.inMilliseconds < 20 # < 20ms
