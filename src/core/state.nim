## Contains pure logic to manipulate `AppState`.
## Implements the "Arena" pattern to avoid memory allocations (GC)
## during the main loop.

import std/[tables, math, monotimes, bitops]
import ../pkgs/manager
import types

proc appendFromArena*(
    state: AppState, offset, len: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Appends data from text arena to buffer with bounds checking
  ## Following DOD: Inline for performance, checks for safety

  # Validate offset and length are non-negative
  if offset < 0 or len < 0:
    return

  # Calculate actual copy length respecting maxLen
  var copyLen = len
  if maxLen >= 0 and maxLen < len:
    copyLen = maxLen
  if copyLen <= 0:
    return

  # Critical bounds check: ensure we don't read past arena end
  let endOffset = offset + copyLen
  if endOffset > state.textArena.len:
    # Clamp to available data
    copyLen = state.textArena.len - offset
    if copyLen <= 0:
      return

  let currentLen = buffer.len
  buffer.setLen(currentLen + copyLen)
  if state.textArena.len > 0 and copyLen > 0:
    copyMem(addr buffer[currentLen], unsafeAddr state.textArena[offset], copyLen)

proc appendName*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  let offset = int(state.soa.hot.locators[idx])
  let len = int(state.soa.hot.nameLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendVersion*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  let nameLen = int(state.soa.hot.nameLens[idx])
  let offset = int(state.soa.hot.locators[idx]) + nameLen
  let len = int(state.soa.cold.verLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendRepo*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  let rIdx = state.soa.cold.repoIndices[idx]
  let rOffset = int(state.repoOffsets[rIdx])
  let rLen = int(state.repoLens[int(rIdx)])
  var copyLen = rLen
  if maxLen >= 0 and maxLen < rLen:
    copyLen = maxLen

  if copyLen > 0:
    let currentLen = buffer.len
    buffer.setLen(currentLen + copyLen)
    copyMem(addr buffer[currentLen], unsafeAddr state.repoArena[rOffset], copyLen)

func getNameLen*(state: AppState, idx: int): int {.inline, noSideEffect.} =
  int(state.soa.hot.nameLens[idx])

func getVersionLen*(state: AppState, idx: int): int {.inline, noSideEffect.} =
  int(state.soa.cold.verLens[idx])

func getRepoLen*(state: AppState, idx: int): int {.inline, noSideEffect.} =
  int(state.repoLens[int(state.soa.cold.repoIndices[idx])])

func getName*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getNameLen(idx))
  state.appendName(idx, result)

func getVersion*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getVersionLen(idx))
  state.appendVersion(idx, result)

func getRepo*(state: AppState, idx: int): string =
  let rIdx = int(state.soa.cold.repoIndices[idx])
  let repoOffset = int(state.repoOffsets[rIdx])
  let repoLen = int(state.repoLens[int(state.soa.cold.repoIndices[idx])])
  if repoOffset + repoLen <= state.repoArena.len:
    result = newStringOfCap(repoLen)
    result.setLen(repoLen)
    copyMem(addr result[0], unsafeAddr state.repoArena[repoOffset], repoLen)
    return result
  return ""

func getPkgId*(state: AppState, idx: int32): string {.noSideEffect.} =
  state.getRepo(int(idx)) & "/" & state.getName(int(idx))

func isSelected*(state: AppState, idx: int): bool {.inline, noSideEffect.} =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    return false
  testBit(state.selectionBits[wordIdx], idx mod 64)

proc toggleSelection*(state: var AppState, idx: int) =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    state.selectionBits.setLen(wordIdx + 1)
  state.selectionBits[wordIdx] =
    state.selectionBits[wordIdx] xor (1'u64 shl (idx mod 64))

func getSelectedCount*(state: AppState): int {.noSideEffect.} =
  result = 0
  for word in state.selectionBits:
    result += countSetBits(word)

proc saveCurrentToDB*(state: var AppState) =
  let db =
    case state.dataSource
    of SourceSystem:
      (if state.searchMode == ModeLocal: addr state.systemDB
      else: addr state.aurDB)
    of SourceNimble:
      addr state.nimbleDB
  db[].soa = state.soa
  db[].textArena = state.textArena
  db[].repos = state.repos
  db[].repoArena = state.repoArena
  db[].repoLens = state.repoLens
  db[].repoOffsets = state.repoOffsets
  db[].isLoaded = true

proc loadFromDB*(state: var AppState, source: DataSource) =
  let db =
    if source == SourceSystem:
      (if state.searchMode == ModeLocal: addr state.systemDB
      else: addr state.aurDB)
    else:
      addr state.nimbleDB
  state.soa = db[].soa
  state.textArena = db[].textArena
  state.repos = db[].repos
  state.repoArena = db[].repoArena
  state.repoLens = db[].repoLens
  state.repoOffsets = db[].repoOffsets

proc switchToNimble*(state: var AppState) =
  if state.dataSource != SourceNimble:
    state.visibleIndices.setLen(0)
    state.detailsCache.clear()
    saveCurrentToDB(state)
    state.dataSource = SourceNimble
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    loadFromDB(state, SourceNimble)
    if not state.nimbleDB.isLoaded:
      requestLoadNimble(state.searchId)

proc switchToSystem*(state: var AppState, mode: SearchMode) =
  if state.dataSource != SourceSystem or state.searchMode != mode:
    state.visibleIndices.setLen(0)
    state.detailsCache.clear()
    saveCurrentToDB(state)
    state.dataSource = SourceSystem
    state.searchMode = mode
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    loadFromDB(state, SourceSystem)
    if mode == ModeLocal:
      if not state.systemDB.isLoaded:
        requestLoadAll(state.searchId)
    else:
      if not state.aurDB.isLoaded:
        requestLoadAur(state.searchId)

proc restoreBaseState*(state: var AppState) =
  if state.baseDataSource == SourceNimble:
    switchToNimble(state)
  else:
    switchToSystem(state, state.baseSearchMode)

proc initPackageDB(): PackageDB =
  PackageDB(
    soa: PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[], flags: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[]),
    ),
    textArena: @[],
    repos: @[],
    repoArena: @[],
    repoLens: @[],
    repoOffsets: @[],
    isLoaded: false,
  )

proc initStringArena*(capacity: int): StringArena =
  var buffer = newSeqOfCap[char](capacity)
  buffer.setLen(capacity)
  StringArena(buffer: buffer, capacity: capacity, offset: 0)

proc allocString*(arena: var StringArena, s: string): StringArenaHandle =
  ## Allocates string in arena with overflow protection
  ## Following DOD: Arena resets when full, raises on oversized strings
  let requiredLen = s.len

  # Check if string is too large for this arena
  if requiredLen > arena.capacity:
    raise newException(
      IndexDefect,
      "String too large for arena: " & $requiredLen & " > " & $arena.capacity,
    )

  # Reset arena if allocation would overflow
  if arena.offset + requiredLen > arena.capacity:
    arena.offset = 0

  # Final safety check after reset
  if arena.offset + requiredLen > arena.capacity:
    # This should not happen if capacity >= requiredLen, but check anyway
    raise newException(IndexDefect, "Arena allocation failed after reset")

  # Safe copy with bounds checking
  if requiredLen > 0:
    copyMem(addr arena.buffer[arena.offset], unsafeAddr s[0], requiredLen)

  result = StringArenaHandle(startOffset: arena.offset, length: requiredLen)
  arena.offset += requiredLen

proc resetArena*(arena: var StringArena) =
  arena.offset = 0

proc newState*(
    initialMode: SearchMode, initialShowDetails: bool, startNimble: bool
): AppState =
  let ds = if startNimble: SourceNimble else: SourceSystem
  AppState(
    soa: PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[], flags: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[]),
    ),
    textArena: @[],
    repos: @[],
    repoArena: @[],
    repoLens: @[],
    repoOffsets: @[],
    systemDB: initPackageDB(),
    aurDB: initPackageDB(),
    nimbleDB: initPackageDB(),
    visibleIndices: @[],
    selectionBits: @[],
    detailsCache: initTable[int32, string](),
    cursor: 0,
    scroll: 0,
    searchBuffer: "",
    searchCursor: 0,
    searchMode: initialMode,
    dataSource: ds,
    baseSearchMode: initialMode,
    baseDataSource: ds,
    viewingSelection: false,
    isSearching: false,
    searchId: 1,
    dataSearchId: 0,
    lastInputTime: getMonoTime(),
    debouncePending: false,
    statusMessage: "",
    showDetails: initialShowDetails,
    needsRedraw: true,
    detailScroll: 0,
    stringArena: initStringArena(64 * 1024),
  )

func toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let realIdx = state.visibleIndices[state.cursor]
    state.toggleSelection(int(realIdx))
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
