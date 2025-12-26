import std/[strutils, tables, math, monotimes, bitops]
import types, simd, pkgManager

proc appendFromArena(
    state: AppState, offset, len: int, buffer: var string, maxLen: int = -1
) {.inline.} =
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
  let rOffset = int(state.repoOffsets[idx])
  let rLen = int(state.repoLens[int(rIdx)])
  var copyLen = rLen
  if maxLen >= 0 and maxLen < rLen:
    copyLen = maxLen

  if copyLen > 0:
    let currentLen = buffer.len
    buffer.setLen(currentLen + copyLen)
    copyMem(addr buffer[currentLen], unsafeAddr state.repoArena[rOffset], copyLen)

func getNameLen*(state: AppState, idx: int): int {.inline.} =
  int(state.soa.hot.nameLens[idx])

func getVersionLen*(state: AppState, idx: int): int {.inline.} =
  int(state.soa.cold.verLens[idx])

func getRepoLen*(state: AppState, idx: int): int {.inline.} =
  int(state.repoLens[int(state.soa.cold.repoIndices[idx])])

func getName*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getNameLen(idx))
  state.appendName(idx, result)

func getVersion*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getVersionLen(idx))
  state.appendVersion(idx, result)

func getRepo*(state: AppState, idx: int): string =
  let repoOffset = int(state.repoOffsets[idx])
  let repoLen = int(state.repoLens[int(state.soa.cold.repoIndices[idx])])
  if repoOffset + repoLen <= state.repoArena.len:
    result = newStringOfCap(repoLen)
    result.setLen(repoLen)
    copyMem(addr result[0], unsafeAddr state.repoArena[repoOffset], repoLen)
    return result
  return ""

func getPkgId*(state: AppState, idx: int32): string =
  state.getRepo(int(idx)) & "/" & state.getName(int(idx))

func getEffectiveQuery*(buffer: string): string =
  if buffer.startsWith("aur/"):
    return buffer[4 ..^ 1]
  if buffer.startsWith("nimble/"):
    return buffer[7 ..^ 1]
  if buffer.startsWith("nim/"):
    return buffer[4 ..^ 1]
  return buffer

proc filterIndices*(state: AppState, query: string, results: var seq[int32]) =
  results.setLen(0)

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

proc isSelected*(state: AppState, idx: int): bool {.inline.} =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    return false
  testBit(state.selectionBits[wordIdx], idx mod 64)

proc toggleSelection*(state: var AppState, idx: int) =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    state.selectionBits.setLen(wordIdx + 1)

  var word = state.selectionBits[wordIdx]
  word = word xor (1'u64 shl (idx mod 64))
  state.selectionBits[wordIdx] = word

proc getSelectedCount*(state: AppState): int =
  result = 0
  for word in state.selectionBits:
    result += countSetBits(word)

proc filterBySelection*(state: AppState, results: var seq[int32]) =
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
    else:
      filterIndices(state, state.searchBuffer, state.visibleIndices)

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
        filterIndices(state, state.searchBuffer, state.visibleIndices)
    else:
      if not state.aurDB.isLoaded:
        requestLoadAur(state.searchId)
      else:
        filterIndices(state, state.searchBuffer, state.visibleIndices)

proc restoreBaseState*(state: var AppState) =
  if state.baseDataSource == SourceNimble:
    switchToNimble(state)
  else:
    switchToSystem(state, state.baseSearchMode)

proc initPackageDB(): PackageDB =
  PackageDB(
    soa: PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[], nameHash: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[], flags: @[]),
    ),
    textArena: @[],
    repos: @[],
    repoArena: @[],
    repoLens: @[],
    repoOffsets: @[],
    isLoaded: false,
  )

proc newState*(
    initialMode: SearchMode, initialShowDetails: bool, startNimble: bool
): AppState =
  let ds = if startNimble: SourceNimble else: SourceSystem
  AppState(
    soa: PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[], nameHash: @[]),
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
  )

func toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let realIdx = state.visibleIndices[state.cursor]
    state.toggleSelection(int(realIdx))
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
