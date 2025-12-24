import std/[strutils, sets, tables, algorithm, math, sequtils, monotimes]
import types, simd, pkgManager

template getName*(state: AppState, p: PackedPackage): string =
  state.textBlocks[p.blockIdx][p.offset ..< p.offset + p.nameLen]

template getVersion*(state: AppState, p: PackedPackage): string =
  let start = p.offset + p.nameLen
  state.textBlocks[p.blockIdx][start ..< start + p.verLen]

template getRepo*(state: AppState, p: PackedPackage): string =
  state.repos[p.repoIdx]

func getPkgId*(state: AppState, idx: int32): string =
  let p = state.pkgs[int(idx)]
  state.getRepo(p) & "/" & state.getName(p)

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
  if cleanQuery.len == 0:
    return toSeq(0 ..< state.pkgs.len).mapIt(int32(it))

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return @[]

  var scored = newSeqOfCap[tuple[idx: int32, score: int]](min(2000, state.pkgs.len))
  for i in 0 ..< state.pkgs.len:
    let p = state.pkgs[i]
    let blockPtr = unsafeAddr state.textBlocks[p.blockIdx][0]
    let namePtr = cast[ptr char](cast[int](blockPtr) + int(p.offset))
    let s = scorePackageSimd(namePtr, int(p.nameLen), ctx)
    if s > 0:
      scored.add((int32(i), s))

  scored.sort do(a, b: auto) -> int:
    cmp(b.score, a.score)
  return scored.mapIt(it.idx)

func filterBySelection*(state: AppState): seq[int32] =
  if state.selected.len == 0:
    return @[]
  result = newSeqOfCap[int32](state.selected.len)
  for i in 0 ..< state.pkgs.len:
    if state.getPkgId(int32(i)) in state.selected:
      result.add(int32(i))

proc saveCurrentToDB*(state: var AppState) =
  if state.dataSource == SourceSystem:
    if state.searchMode == ModeLocal:
      state.systemDB.pkgs = state.pkgs
      state.systemDB.textBlocks = state.textBlocks
      state.systemDB.repos = state.repos
      state.systemDB.isLoaded = true
  else:
    state.nimbleDB.pkgs = state.pkgs
    state.nimbleDB.textBlocks = state.textBlocks
    state.nimbleDB.repos = state.repos
    state.nimbleDB.isLoaded = true

proc loadFromDB*(state: var AppState, source: DataSource) =
  if source == SourceSystem:
    state.pkgs = state.systemDB.pkgs
    state.textBlocks = state.systemDB.textBlocks
    state.repos = state.systemDB.repos
  else:
    state.pkgs = state.nimbleDB.pkgs
    state.textBlocks = state.nimbleDB.textBlocks
    state.repos = state.nimbleDB.repos

proc switchToNimble*(state: var AppState) =
  if state.dataSource != SourceNimble:
    state.visibleIndices = @[]
    saveCurrentToDB(state)
    state.dataSource = SourceNimble
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selected.clear()
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
    state.selected.clear()
    loadFromDB(state, SourceSystem)
    if not state.systemDB.isLoaded:
      requestLoadAll(state.searchId)
    else:
      state.visibleIndices = filterIndices(state, state.searchBuffer)

proc restoreBaseState*(state: var AppState) =
  if state.baseDataSource == SourceNimble:
    switchToNimble(state)
  else:
    switchToSystem(state, state.baseSearchMode)

proc newState*(
    initialMode: SearchMode, initialShowDetails: bool, useVim: bool, startNimble: bool
): AppState =
  let ds = if startNimble: SourceNimble else: SourceSystem
  AppState(
    pkgs: @[],
    textBlocks: @[],
    repos: @[],
    systemDB: PackageDB(pkgs: @[], textBlocks: @[], repos: @[], isLoaded: false),
    nimbleDB: PackageDB(pkgs: @[], textBlocks: @[], repos: @[], isLoaded: false),
    visibleIndices: @[],
    selected: initHashSet[string](),
    detailsCache: initTable[string, string](),
    cursor: 0,
    scroll: 0,
    searchBuffer: "",
    commandBuffer: "",
    searchMode: initialMode,
    dataSource: ds,
    baseSearchMode: initialMode,
    baseDataSource: ds,
    isSearching: false,
    showDetails: initialShowDetails,
    detailScroll: 0,
    viewingSelection: false,
    inputMode: if useVim: ModeVimNormal else: ModeStandard,
    searchId: 1,
    lastInputTime: getMonoTime(),
    debouncePending: false,
    statusMessage: "",
  )

func toggleSelection*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let id = state.getPkgId(state.visibleIndices[state.cursor])
    if id in state.selected:
      state.selected.excl(id)
    else:
      state.selected.incl(id)
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
