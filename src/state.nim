import std/[strutils, sets, tables, algorithm, math, sequtils, monotimes, bitops]
import types, simd, pkgManager

template getName*(state: AppState, idx: int): string =
  let offset = int(state.soa.locators[idx])
  let len = int(state.soa.nameLens[idx])
  cast[string](state.textArena[offset ..< offset + len])

template getVersion*(state: AppState, idx: int): string =
  let nameLen = int(state.soa.nameLens[idx])
  let offset = int(state.soa.locators[idx]) + nameLen
  let len = int(state.soa.verLens[idx])
  cast[string](state.textArena[offset ..< offset + len])

template getRepo*(state: AppState, idx: int): string =
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

func filterIndices*(state: AppState, query: string): seq[int32] =
  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()

  if state.searchMode == ModeAUR and cleanQuery.len == 0:
    return @[]

  let totalPkgs = state.soa.locators.len

  if cleanQuery.len == 0:
    return toSeq(0 ..< totalPkgs).mapIt(int32(it))

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return @[]

  var scored = newSeqOfCap[tuple[idx: int32, score: int]](min(2000, totalPkgs))

  if state.textArena.len == 0:
    return @[]
  let arenaBase = cast[int](unsafeAddr state.textArena[0])

  for i in 0 ..< totalPkgs:
    let offset = int(state.soa.locators[i])
    let namePtr = cast[ptr char](arenaBase + offset)

    let s = scorePackageSimd(namePtr, int(state.soa.nameLens[i]), ctx)
    if s > 0:
      scored.add((int32(i), s))

  scored.sort do(a, b: auto) -> int:
    cmp(b.score, a.score)
  return scored.mapIt(it.idx)

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

func filterBySelection*(state: AppState): seq[int32] =
  result = newSeqOfCap[int32](state.getSelectedCount())
  let totalPkgs = state.soa.locators.len
  for i, word in state.selectionBits:
    if word == 0:
      continue
    for bit in 0 .. 63:
      if testBit(word, bit):
        let realIdx = i * 64 + bit
        if realIdx < totalPkgs:
          result.add(int32(realIdx))

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
    state.visibleIndices = @[]
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
      state.visibleIndices = filterIndices(state, state.searchBuffer)

proc switchToSystem*(state: var AppState, mode: SearchMode) =
  if state.dataSource != SourceSystem or state.searchMode != mode:
    state.visibleIndices = @[]
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
        state.visibleIndices = filterIndices(state, state.searchBuffer)
    else:
      # ModeAUR: Clear current data to prepare for search results
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
    initialMode: SearchMode, initialShowDetails: bool, useVim: bool, startNimble: bool
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
    commandBuffer: "",
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
    # FIX: Assign initial values correctly
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
