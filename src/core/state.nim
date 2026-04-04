## Contains pure logic to manipulate `AppState`.
## Implements the "Arena" pattern to avoid memory allocations (GC)
## during the main loop.

import std/[tables, math, monotimes, bitops]
import types
import ../pkgs/[index_builder, indexes]
import systems/search_system

proc appendFromArena*(
    textArena: openArray[char], offset, len: int, buffer: var string, maxLen: int = -1
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
  if endOffset > textArena.len:
    # Clamp to available data
    copyLen = textArena.len - offset
    if copyLen <= 0:
      return

  let currentLen = buffer.len
  buffer.setLen(currentLen + copyLen)
  if textArena.len > 0 and copyLen > 0:
    copyMem(addr buffer[currentLen], unsafeAddr textArena[offset], copyLen)

proc appendName*(
    soa: PackageSOA,
    textArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let offset = int(soa.hot.locators[idx])
  let len = int(soa.hot.nameLens[idx])
  appendFromArena(textArena, offset, len, buffer, maxLen)

proc appendVersion*(
    soa: PackageSOA,
    textArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let nameLen = int(soa.hot.nameLens[idx])
  let offset = int(soa.hot.locators[idx]) + nameLen
  let len = int(soa.cold.verLens[idx])
  appendFromArena(textArena, offset, len, buffer, maxLen)

proc appendRepo*(
    soa: PackageSOA,
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let rIdx = soa.cold.repoIndices[idx]
  let rOffset = int(repoOffsets[rIdx])
  let rLen = int(repoLens[int(rIdx)])
  var copyLen = rLen
  if maxLen >= 0 and maxLen < rLen:
    copyLen = maxLen

  if copyLen > 0:
    let currentLen = buffer.len
    buffer.setLen(currentLen + copyLen)
    copyMem(addr buffer[currentLen], unsafeAddr repoArena[rOffset], copyLen)

func getNameLen*(soa: PackageSOA, idx: int): int {.inline, noSideEffect.} =
  int(soa.hot.nameLens[idx])

func getVersionLen*(soa: PackageSOA, idx: int): int {.inline, noSideEffect.} =
  int(soa.cold.verLens[idx])

func getRepoLen*(soa: PackageSOA, repoLens: openArray[uint8], idx: int): int {.
    inline, noSideEffect.} =
  int(repoLens[int(soa.cold.repoIndices[idx])])

func getName*(soa: PackageSOA, textArena: openArray[char], idx: int): string =
  result = newStringOfCap(getNameLen(soa, idx))
  appendName(soa, textArena, idx, result)

func getVersion*(soa: PackageSOA, textArena: openArray[char], idx: int): string =
  result = newStringOfCap(getVersionLen(soa, idx))
  appendVersion(soa, textArena, idx, result)

func getRepo*(
    soa: PackageSOA,
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int,
): string =
  let rIdx = int(soa.cold.repoIndices[idx])
  let repoOffset = int(repoOffsets[rIdx])
  let repoLen = int(repoLens[int(soa.cold.repoIndices[idx])])
  if repoOffset + repoLen <= repoArena.len:
    result = newStringOfCap(repoLen)
    result.setLen(repoLen)
    copyMem(addr result[0], unsafeAddr repoArena[repoOffset], repoLen)
    return result
  return ""

func getPkgId*(
    soa: PackageSOA,
    textArena: openArray[char],
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int32,
): string {.noSideEffect.} =
  getRepo(soa, repoOffsets, repoLens, repoArena, int(idx)) & "/" &
    getName(soa, textArena, int(idx))

func isSelected*(selectionBits: openArray[uint64], idx: int): bool {.inline, noSideEffect.} =
  let wordIdx = idx div 64
  if wordIdx >= selectionBits.len:
    return false
  testBit(selectionBits[wordIdx], idx mod 64)

proc toggleSelection*(state: var AppState, idx: int) =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    state.selectionBits.setLen(wordIdx + 1)
  state.selectionBits[wordIdx] =
    state.selectionBits[wordIdx] xor (1'u64 shl (idx mod 64))

func getSelectedCount*(selectionBits: openArray[uint64]): int {.noSideEffect.} =
  result = 0
  for word in selectionBits:
    result += countSetBits(word)

proc slotForIndexKind(kind: IndexedSourceKind): SourceSlot =
  case kind
  of iskSystem:
    SlotSystem
  of iskAur:
    SlotAur
  of iskNimble:
    SlotNimble

proc activeView*(state: var AppState): ptr SourceIndexView {.inline.} =
  addr state.sourceViews[state.activeSlot]

proc currentPackageCount*(state: var AppState): int {.inline.} =
  packageCount(state.activeView)

proc rebuildVisible*(state: var AppState) =
  if state.viewingSelection:
    filterBySelection(
      state.selectionBits, state.currentPackageCount(), state.visibleIndices
    )
  else:
    filterIndices(state.searchBuffer, state.activeView, state.visibleIndices)

proc syncSelectionCapacity(state: var AppState) =
  let requiredWords = (state.currentPackageCount() + 63) div 64
  if state.selectionBits.len > requiredWords:
    state.selectionBits.setLen(requiredWords)

proc activateCurrentSource*(state: var AppState) =
  state.activeSlot = sourceSlot(state.dataSource, state.searchMode)
  state.syncSelectionCapacity()

proc closeIndexedSources*(state: var AppState) =
  for slot in SourceSlot:
    state.sourceViews[slot].close()

proc prepareIndexedSources*(state: var AppState, indexDir: string = "") =
  let runtimeDir =
    if indexDir.len > 0:
      indexDir
    else:
      defaultRuntimeIndexDir()
  let validated = ensureRuntimeIndexes(runtimeDir)
  for slot in SourceSlot:
    state.sourceViews[slot].close()
  for item in validated:
    let slot = slotForIndexKind(item.source)
    state.sourceViews[slot] = openValidatedSourceIndex(item)
    prefaultHotSections(addr state.sourceViews[slot])
  state.activateCurrentSource()
  state.rebuildVisible()

proc switchToNimble*(state: var AppState) =
  if state.dataSource != SourceNimble:
    state.visibleIndices.setLen(0)
    state.detailsCache.clear()
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.dataSource = SourceNimble
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    state.activateCurrentSource()
    state.rebuildVisible()

proc switchToSystem*(state: var AppState, mode: SearchMode) =
  if state.dataSource != SourceSystem or state.searchMode != mode:
    state.visibleIndices.setLen(0)
    state.detailsCache.clear()
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.dataSource = SourceSystem
    state.searchMode = mode
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    state.activateCurrentSource()
    state.rebuildVisible()

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
    sourceViews: default(array[SourceSlot, SourceIndexView]),
    activeSlot: sourceSlot(ds, initialMode),
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
    detailTargetSince: getMonoTime(),
    debouncePending: false,
    statusMessage: "",
    showDetails: initialShowDetails,
    needsRedraw: true,
    detailScroll: 0,
    lastDetailIdx: -1,
    pendingDetailIdx: -1,
    pendingDetailSlot: sourceSlot(ds, initialMode),
    detailRequestInFlight: false,
    stringArena: initStringArena(64 * 1024),
  )

func toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let realIdx = state.visibleIndices[state.cursor]
    state.toggleSelection(int(realIdx))
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
