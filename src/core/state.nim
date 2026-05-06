## State facade and constructors.
##
## This module intentionally re-exports state-related helpers so most callers can
## import a single `core/state` surface.

import std/[monotimes, sets]
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
  ## Constructs the full mutable runtime state with deterministic defaults.
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
    sourceIndexStamps: default(array[SourceSlot, int64]),
    lastIndexPollTime: getMonoTime(),
    visibleIndices: @[],
    visibleAll: false,
    visibleAllCount: 0,
    selectionBits: @[],
    selectedPackages: initHashSet[string](),
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
    indexRefreshInFlight: false,
    searchId: 1,
    dataSearchId: 0,
    lastInputTime: getMonoTime(),
    detailTargetSince: getMonoTime(),
    debouncePending: false,
    statusMessage: "",
    showDetails: initialShowDetails,
    detailsAnimationEnabled: true,
    detailAnimationStyle: DetailAnimationBlocks,
    detailAnimationSpeed: DetailAnimationFast,
    needsRedraw: true,
    detailScroll: 0,
    lastDetailIdx: -1,
    pendingDetailIdx: -1,
    detailScramble:
      DetailScramble(pkgIdx: -1, pkgSlot: sourceSlot(ds, mode), active: false),
    pendingDetailSlot: sourceSlot(ds, mode),
    detailRequestInFlight: false,
    stringArena: initStringArena(8 * 1024),
  )

proc toggleSelectionAtCursor*(state: var AppState) =
  ## Toggles selection for the currently focused visible row and advances cursor.
  if state.visibleCount() > 0:
    let realIdx = state.visibleIdxAt(state.cursor)
    state.toggleSelection(state.activeView, int(realIdx))
    if state.cursor < state.visibleCount() - 1:
      state.cursor.inc()
