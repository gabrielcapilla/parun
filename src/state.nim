import std/[strutils, sets, tables, algorithm, math]
import types, simd

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
  return buffer

func filterIndices*(state: AppState, query: string): seq[int32] =
  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()

  if cleanQuery.len == 0:
    result = newSeq[int32](state.pkgs.len)
    for i in 0 ..< state.pkgs.len:
      result[i] = int32(i)
    return

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
  result = newSeqOfCap[int32](scored.len)
  for item in scored:
    result.add(item.idx)

func filterBySelection*(state: AppState): seq[int32] =
  result = newSeqOfCap[int32](state.selected.len)
  if state.selected.len == 0:
    return
  for i in 0 ..< state.pkgs.len:
    let id = state.getPkgId(int32(i))
    if id in state.selected:
      result.add(int32(i))

func newState*(
    initialMode: SearchMode, initialShowDetails: bool, useVim: bool, startNimble: bool
): AppState =
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
    isSearching: false,
    showDetails: initialShowDetails,
    detailScroll: 0,
    viewingSelection: false,
    inputMode: if useVim: ModeVimNormal else: ModeStandard,
    dataSource: if startNimble: SourceNimble else: SourceSystem,
    searchId: 1,
  )

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

func toggleSelection*(state: var AppState) =
  if state.visibleIndices.len > 0:
    let id = state.getPkgId(state.visibleIndices[state.cursor])
    if id in state.selected:
      state.selected.excl(id)
    else:
      state.selected.incl(id)
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()
