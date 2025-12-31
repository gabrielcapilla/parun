## Contains pure logic to manipulate `AppState`.
## Implements the "Arena" pattern to avoid memory allocations (GC)
## during the main loop.

import std/[strutils, tables, math, monotimes, bitops]
import ../pkgs/manager
import ../utils/simd
import types

proc appendFromArena(
    state: AppState, offset, len: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Copies bytes from the global arena to a destination string buffer.
  ## Uses low-level `copyMem` for maximum speed.
  var copyLen = len
  if maxLen >= 0 and maxLen < len:
    copyLen = maxLen
  if copyLen <= 0:
    return

  let currentLen = buffer.len
  buffer.setLen(currentLen + copyLen)
  if state.textArena.len > 0:
    copyMem(addr buffer[currentLen], unsafeAddr state.textArena[offset], copyLen)

proc appendName*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  ## Retrieves the name of package `idx` and appends it to the buffer.
  let offset = int(state.soa.hot.locators[idx])
  let len = int(state.soa.hot.nameLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendVersion*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  ## Retrieves the version of package `idx` and appends it to the buffer.
  ## Calculates offset assuming version follows name in memory.
  let nameLen = int(state.soa.hot.nameLens[idx])
  let offset = int(state.soa.hot.locators[idx]) + nameLen
  let len = int(state.soa.cold.verLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendRepo*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  ## Retrieves the repository name of package `idx`.
  let rIdx = state.soa.cold.repoIndices[idx]
  let rOffset = int(state.repoOffsets[idx])
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
  ## Creates a new string with the name (Warning: Allocates GC memory).
  result = newStringOfCap(state.getNameLen(idx))
  state.appendName(idx, result)

func getVersion*(state: AppState, idx: int): string =
  ## Creates a new string with the version (Warning: Allocates GC memory).
  result = newStringOfCap(state.getVersionLen(idx))
  state.appendVersion(idx, result)

func getRepo*(state: AppState, idx: int): string =
  ## Creates a new string with the repository (Warning: Allocates GC memory).
  let repoOffset = int(state.repoOffsets[idx])
  let repoLen = int(state.repoLens[int(state.soa.cold.repoIndices[idx])])
  if repoOffset + repoLen <= state.repoArena.len:
    result = newStringOfCap(repoLen)
    result.setLen(repoLen)
    copyMem(addr result[0], unsafeAddr state.repoArena[repoOffset], repoLen)
    return result
  return ""

func getPkgId*(state: AppState, idx: int32): string {.noSideEffect.} =
  ## Returns unique identifier "repo/name".
  state.getRepo(int(idx)) & "/" & state.getName(int(idx))

func getEffectiveQuery*(buffer: string): string {.noSideEffect.} =
  ## Extracts the real query by removing magic prefixes (aur/, nimble/).
  if buffer.startsWith("aur/"):
    return buffer[4 ..^ 1]
  if buffer.startsWith("nimble/"):
    return buffer[7 ..^ 1]
  if buffer.startsWith("nim/"):
    return buffer[4 ..^ 1]
  return buffer

proc filterIndices*(state: AppState, query: string, results: var seq[int32]) =
  ## Filtering System (Hot Path).
  ##
  ## Executes SIMD search over all packages.
  ##
  ## Optimizations:
  ## 1. **Zero Allocations:** Reuses `results` buffer.
  ## 2. **Linear Access:** Scans `textArena` sequentially.
  ## 3. **SIMD:** Uses `scorePackageSimd`.
  let count = results.len
  results.setLen(0)
  results.setLen(count)

  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()

  let totalPkgs = state.soa.hot.locators.len

  if cleanQuery.len == 0:
    results.setLen(totalPkgs)
    for i in 0 ..< totalPkgs:
      results[i] = int32(i)
    return

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return

  var buf: ResultsBuffer
  buf.count = 0

  if state.textArena.len == 0:
    return
  let arenaBase = cast[int](unsafeAddr state.textArena[0])

  for i in 0 ..< totalPkgs:
    if buf.count >= 2000:
      break

    let offset = int(state.soa.hot.locators[i])
    let namePtr = cast[ptr char](arenaBase + offset)

    let s = scorePackageSimd(namePtr, int(state.soa.hot.nameLens[i]), ctx)
    if s > 0:
      buf.indices[buf.count] = int32(i)
      buf.scores[buf.count] = s
      inc(buf.count)

  countingSortResults(buf)

  results.setLen(buf.count)
  for i in 0 ..< buf.count:
    results[i] = buf.indices[i]

func isSelected*(state: AppState, idx: int): bool {.inline, noSideEffect.} =
  ## Checks if a package is selected using bitwise operations.
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    return false
  testBit(state.selectionBits[wordIdx], idx mod 64)

proc toggleSelection*(state: var AppState, idx: int) =
  ## Toggles selection state of a package (Bitwise XOR).
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    state.selectionBits.setLen(wordIdx + 1)

  var word = state.selectionBits[wordIdx]
  word = word xor (1'u64 shl (idx mod 64))
  state.selectionBits[wordIdx] = word

func getSelectedCount*(state: AppState): int {.noSideEffect.} =
  ## Counts total selected packages (Population Count).
  result = 0
  for word in state.selectionBits:
    result += countSetBits(word)

proc filterBySelection*(state: AppState, results: var seq[int32]) =
  ## Filters the visible list to show only selected items.
  results.setLen(0)
  let totalPkgs = state.soa.hot.locators.len
  for i, word in state.selectionBits:
    if word == 0:
      continue
    for bit in 0 .. 63:
      if testBit(word, bit):
        let realIdx = i * 64 + bit
        if realIdx < totalPkgs:
          results.add(int32(realIdx))

proc saveCurrentToDB*(state: var AppState) =
  ## Persists current state to the corresponding DB.
  if state.dataSource == SourceSystem:
    if state.searchMode == ModeLocal:
      state.systemDB.soa = state.soa
      state.systemDB.textArena = state.textArena
      state.systemDB.repos = state.repos
      state.systemDB.repoArena = state.repoArena
      state.systemDB.repoLens = state.repoLens
      state.systemDB.repoOffsets = state.repoOffsets
      state.systemDB.isLoaded = true
    else:
      state.aurDB.soa = state.soa
      state.aurDB.textArena = state.textArena
      state.aurDB.repos = state.repos
      state.aurDB.repoArena = state.repoArena
      state.aurDB.repoLens = state.repoLens
      state.aurDB.repoOffsets = state.repoOffsets
      state.aurDB.isLoaded = true
  else:
    state.nimbleDB.soa = state.soa
    state.nimbleDB.textArena = state.textArena
    state.nimbleDB.repos = state.repos
    state.nimbleDB.repoArena = state.repoArena
    state.nimbleDB.repoLens = state.repoLens
    state.nimbleDB.repoOffsets = state.repoOffsets
    state.nimbleDB.isLoaded = true

proc loadFromDB*(state: var AppState, source: DataSource) =
  ## Loads state from an in-memory DB.
  if source == SourceSystem:
    if state.searchMode == ModeLocal:
      state.soa = state.systemDB.soa
      state.textArena = state.systemDB.textArena
      state.repos = state.systemDB.repos
      state.repoArena = state.systemDB.repoArena
      state.repoLens = state.systemDB.repoLens
      state.repoOffsets = state.systemDB.repoOffsets
    else:
      state.soa = state.aurDB.soa
      state.textArena = state.aurDB.textArena
      state.repos = state.aurDB.repos
      state.repoArena = state.aurDB.repoArena
      state.repoLens = state.aurDB.repoLens
      state.repoOffsets = state.aurDB.repoOffsets
  else:
    state.soa = state.nimbleDB.soa
    state.textArena = state.nimbleDB.textArena
    state.repos = state.nimbleDB.repos
    state.repoArena = state.nimbleDB.repoArena
    state.repoLens = state.nimbleDB.repoLens
    state.repoOffsets = state.nimbleDB.repoOffsets

proc switchToNimble*(state: var AppState) =
  if state.dataSource != SourceNimble:
    state.visibleIndices.setLen(0)
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
      hot: PackageHot(locators: @[], nameLens: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[], flags: @[]),
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
  let requiredLen = s.len
  let newOffset = arena.offset + requiredLen

  if newOffset > arena.capacity:
    arena.offset = 0
    if requiredLen > arena.capacity:
      raise newException(IndexDefect, "String too large for arena")

  copyMem(addr arena.buffer[arena.offset], unsafeAddr s[0], requiredLen)

  result = StringArenaHandle(startOffset: arena.offset, length: requiredLen)

  arena.offset = newOffset

proc resetArena*(arena: var StringArena) =
  arena.offset = 0

proc newState*(
    initialMode: SearchMode, initialShowDetails: bool, startNimble: bool
): AppState =
  let ds = if startNimble: SourceNimble else: SourceSystem
  AppState(
    soa: PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[], flags: @[]),
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

func isInstalled*(state: AppState, idx: int): bool {.inline, noSideEffect.} =
  (state.soa.cold.flags[idx] and 1) != 0

func toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let realIdx = state.visibleIndices[state.cursor]
    state.toggleSelection(int(realIdx))
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
