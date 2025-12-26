import std/[strutils, tables, algorithm, math, monotimes, bitops]
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
  let offset = int(state.soa.locators[idx])
  let len = int(state.soa.nameLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendVersion*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  let nameLen = int(state.soa.nameLens[idx])
  let offset = int(state.soa.locators[idx]) + nameLen
  let len = int(state.soa.verLens[idx])
  appendFromArena(state, offset, len, buffer, maxLen)

proc appendRepo*(state: AppState, idx: int, buffer: var string, maxLen: int = -1) =
  let rIdx = state.soa.repoIndices[idx]
  let rName = state.repos[rIdx]
  let len = rName.len
  var copyLen = len
  if maxLen >= 0 and maxLen < len:
    copyLen = maxLen

  if copyLen > 0:
    let currentLen = buffer.len
    buffer.setLen(currentLen + copyLen)
    copyMem(addr buffer[currentLen], unsafeAddr rName[0], copyLen)

func getNameLen*(state: AppState, idx: int): int {.inline.} =
  int(state.soa.nameLens[idx])
func getVersionLen*(state: AppState, idx: int): int {.inline.} =
  int(state.soa.verLens[idx])
func getRepoLen*(state: AppState, idx: int): int {.inline.} =
  state.repos[state.soa.repoIndices[idx]].len

func getName*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getNameLen(idx))
  state.appendName(idx, result)

func getVersion*(state: AppState, idx: int): string =
  result = newStringOfCap(state.getVersionLen(idx))
  state.appendVersion(idx, result)

func getRepo*(state: AppState, idx: int): string =
  state.repos[state.soa.repoIndices[idx]]

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

  if state.searchMode == ModeAUR and cleanQuery.len == 0:
    return

  let totalPkgs = state.soa.locators.len

  if cleanQuery.len == 0:
    results.setLen(totalPkgs)
    for i in 0 ..< totalPkgs:
      results[i] = int32(i)
    return

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return

  var scored = newSeqOfCap[tuple[idx: int32, score: int]](min(2000, totalPkgs))

  if state.textArena.len == 0:
    return
  let arenaBase = cast[int](unsafeAddr state.textArena[0])

  for i in 0 ..< totalPkgs:
    let offset = int(state.soa.locators[i])
    let namePtr = cast[ptr char](arenaBase + offset)

    let s = scorePackageSimd(namePtr, int(state.soa.nameLens[i]), ctx)
    if s > 0:
      scored.add((int32(i), s))

  scored.sort do(a, b: auto) -> int:
    cmp(b.score, a.score)

  results.setLen(scored.len)
  for i in 0 ..< scored.len:
    results[i] = scored[i].idx

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
  let totalPkgs = state.soa.locators.len
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
      state.systemDB.isLoaded = true
  else:
    state.nimbleDB.soa = state.soa
    state.nimbleDB.textArena = state.textArena
    state.nimbleDB.repos = state.repos
    state.nimbleDB.isLoaded = true

proc loadFromDB*(state: var AppState, source: DataSource) =
  if source == SourceSystem:
    state.soa = state.systemDB.soa
    state.textArena = state.systemDB.textArena
    state.repos = state.systemDB.repos
  else:
    state.soa = state.nimbleDB.soa
    state.textArena = state.nimbleDB.textArena
    state.repos = state.nimbleDB.repos

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

    if mode == ModeLocal:
      loadFromDB(state, SourceSystem)
      if not state.systemDB.isLoaded:
        requestLoadAll(state.searchId)
      else:
        filterIndices(state, state.searchBuffer, state.visibleIndices)
    else:
      state.soa.locators.setLen(0)
      state.soa.nameLens.setLen(0)
      state.soa.verLens.setLen(0)
      state.soa.repoIndices.setLen(0)
      state.soa.flags.setLen(0)
      state.textArena.setLen(0)
      state.repos.setLen(0)

proc restoreBaseState*(state: var AppState) =
  if state.baseDataSource == SourceNimble:
    switchToNimble(state)
  else:
    switchToSystem(state, state.baseSearchMode)

proc initPackageDB(): PackageDB =
  PackageDB(
    soa: PackageSOA(
      locators: @[], nameLens: @[], verLens: @[], repoIndices: @[], flags: @[]
    ),
    textArena: @[],
    repos: @[],
    isLoaded: false,
  )

proc newState*(
    initialMode: SearchMode, initialShowDetails: bool, startNimble: bool
): AppState =
  let ds = if startNimble: SourceNimble else: SourceSystem
  AppState(
    soa: PackageSOA(
      locators: @[], nameLens: @[], verLens: @[], repoIndices: @[], flags: @[]
    ),
    textArena: @[],
    repos: @[],
    systemDB: initPackageDB(),
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
