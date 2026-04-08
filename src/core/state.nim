## State facade and constructors.

import std/monotimes
import types
import ../storage/indexes
import state_soa, detail_cache, state_sources, string_arena

export state_soa
export detail_cache
export state_sources
export string_arena

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

proc newState*(
    initialSlot: SourceSlot,
    initialShowDetails: bool,
    enabledSlots: set[SourceSlot],
    explicitSourceSelection: bool,
): AppState =
  let start = modeForSlot(initialSlot)
  let ds = start.source
  let mode = start.mode
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
    enabledSlots: enabledSlots,
    runtimeIndexDir: "",
    activeSlot: sourceSlot(ds, mode),
    visibleIndices: @[],
    visibleAll: false,
    visibleAllCount: 0,
    selectionBits: @[],
    detailsCache: initDetailCache(),
    cursor: 0,
    scroll: 0,
    searchBuffer: "",
    searchCursor: 0,
    searchMode: mode,
    dataSource: ds,
    baseSearchMode: mode,
    baseDataSource: ds,
    baseSlot: sourceSlot(ds, mode),
    explicitSourceSelection: explicitSourceSelection,
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
    pendingDetailSlot: sourceSlot(ds, mode),
    detailRequestInFlight: false,
    stringArena: initStringArena(8 * 1024),
  )

func toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleCount() > 0:
    let realIdx = state.visibleIdxAt(state.cursor)
    state.toggleSelection(int(realIdx))
    if state.cursor < state.visibleCount() - 1:
      state.cursor.inc()
