import std/[monotimes, sets]
import model
import ../index/indexes
import layout, detail_cache, sources

export layout
export detail_cache
export sources

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
    sourceViews: default(array[SourceSlot, SourceIndexView]),
    enabledSlots: enabledSlots,
    runtimeIndexDir: "",
    activeSlot: sourceSlot(ds, mode),
    sourceIndexStamps: default(array[SourceSlot, int64]),
    lastIndexPollTime: getMonoTime(),
    visibleIndices: @[],
    visibleAll: false,
    visibleAllCount: 0,
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
    indexRefreshInFlight: false,
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
    detailEnrichmentInFlight: false,
    detailEnrichmentIdx: -1,
    detailEnrichmentSlot: sourceSlot(ds, mode),
    detailGeneration: 1,
  )

proc toggleSelectionAtCursor*(state: var AppState) =
  if state.visibleCount() > 0:
    let realIdx = state.visibleIdxAt(state.cursor)
    state.toggleSelection(state.activeView, int(realIdx))
    if state.cursor < state.visibleCount() - 1:
      state.cursor.inc()
