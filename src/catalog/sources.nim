import std/[monotimes, os, times]
import model
import ../sources/index_refresh
import ../index/indexes
import search, detail_cache, selection

proc indexKindForSlot(slot: SourceSlot): IndexedSourceKind =
  case slot
  of SlotSystem: iskSystem
  of SlotAur: iskAur
  of SlotNimble: iskNimble
  of SlotMerged: iskSystem

proc modeForSlot*(slot: SourceSlot): tuple[source: DataSource, mode: SearchMode] =
  case slot
  of SlotSystem:
    (SourceSystem, ModeLocal)
  of SlotAur:
    (SourceSystem, ModeAUR)
  of SlotNimble:
    (SourceNimble, ModeLocal)
  of SlotMerged:
    (SourceSystem, ModeLocal)

proc enabledIndexKinds(state: AppState): set[IndexedSourceKind] =
  for slot in state.enabledSlots:
    if slot != SlotMerged:
      result.incl(indexKindForSlot(slot))

proc slotIndexPath(state: AppState, slot: SourceSlot): string =
  let runtimeDir =
    if state.runtimeIndexDir.len > 0:
      state.runtimeIndexDir
    else:
      defaultRuntimeIndexDir()
  if slot == SlotMerged:
    runtimeMergedIndexPath(runtimeDir, state.enabledIndexKinds())
  else:
    runtimeSourceIndexPath(runtimeDir, indexKindForSlot(slot))

proc indexStamp(path: string): int64 =
  if not fileExists(path):
    return 0
  try:
    let modified = getLastModificationTime(path)
    modified.toUnix() * 1_000_000_000'i64 + int64(modified.nanosecond)
  except CatchableError:
    0'i64

proc ensureSlotViewLoaded(state: var AppState, slot: SourceSlot): bool =
  if valid(addr state.sourceViews[slot]):
    return true

  let runtimeDir =
    if state.runtimeIndexDir.len > 0:
      state.runtimeIndexDir
    else:
      defaultRuntimeIndexDir()

  try:
    if slot == SlotMerged:
      let enabledKinds = state.enabledIndexKinds()
      if enabledKinds.len == 0:
        return false
      discard prepareRuntimeIndexesAsync(runtimeDir, enabledKinds)
      let mergedPath = runtimeMergedIndexPath(runtimeDir, enabledKinds)
      let merged = validateSourceIndex(mergedPath, deep = false)
      if not merged.valid:
        scheduleIndexRefresh(runtimeDir, enabledKinds, mergedOnly = true)
        return false
      var nextView = openValidatedSourceIndex(merged)
      state.sourceViews[SlotMerged].close()
      state.sourceViews[SlotMerged] = nextView
      state.sourceIndexStamps[SlotMerged] = indexStamp(mergedPath)
      return true

    let validated = prepareRuntimeIndexesAsync(runtimeDir, {indexKindForSlot(slot)})
    if validated.len == 0 or not validated[0].valid:
      return false
    var nextView = openValidatedSourceIndex(validated[0])
    state.sourceViews[slot].close()
    state.sourceViews[slot] = nextView
    state.sourceIndexStamps[slot] = indexStamp(validated[0].path)
    true
  except CatchableError:
    false

proc closeInactiveSourceViews(state: var AppState, keep: set[SourceSlot]) =
  for slot in SourceSlot:
    if slot notin keep:
      state.sourceViews[slot].close()

proc activeView*(state: var AppState): ptr SourceIndexView {.inline.} =
  addr state.sourceViews[state.activeSlot]

proc currentPackageCount*(state: var AppState): int {.inline.} =
  packageCount(state.activeView)

func visibleCount*(state: AppState): int {.inline, noSideEffect.} =
  if state.visibleAll:
    int(state.visibleAllCount)
  else:
    state.visibleIndices.len

func visibleIdxAt*(state: AppState, row: int): int32 {.inline, noSideEffect.} =
  if state.visibleAll:
    int32(row)
  else:
    state.visibleIndices[row]

proc clearVisible*(state: var AppState) =
  state.visibleIndices = @[]
  state.visibleAll = false
  state.visibleAllCount = 0

proc markIndexing(state: var AppState) =
  state.clearVisible()
  state.statusMessage = "Indexing..."
  state.indexRefreshInFlight = true
  state.needsRedraw = true

proc resetSourceTransition(state: var AppState) =
  state.clearVisible()
  clearDetailCache(state.detailsCache)
  state.detailGeneration.inc()
  state.wrappedDetails = @[]
  state.pendingDetailIdx = -1
  state.detailScramble.active = false
  state.detailRequestInFlight = false
  state.detailEnrichmentInFlight = false
  state.detailEnrichmentIdx = -1
  state.cursor = 0
  state.scroll = 0

proc rebuildVisible*(state: var AppState)

proc finishSourceTransition(state: var AppState) =
  if state.ensureSlotViewLoaded(state.activeSlot):
    state.closeInactiveSourceViews({state.activeSlot})
    state.rebuildVisible()
    state.statusMessage = ""
    state.indexRefreshInFlight = false
  else:
    state.markIndexing()

proc rebuildVisible*(state: var AppState) =
  if state.viewingSelection:
    let selectionError = filterBySelectionBuffered(
      state.selectedPackages, state.activeView, state.visibleIndices
    )
    state.statusMessage = selectionError
    state.visibleAll = false
    state.visibleAllCount = 0
  else:
    let filterError = filterIndices(
      state.searchBuffer,
      state.activeView,
      state.visibleIndices,
      state.visibleAll,
      state.visibleAllCount,
      addr state.perf,
    )
    state.statusMessage = filterError

proc switchToMerged*(state: var AppState): bool =
  if state.enabledSlots.len <= 1:
    return true
  if state.activeSlot != SlotMerged:
    state.resetSourceTransition()
    state.dataSource = SourceSystem
    state.searchMode = ModeLocal
    state.activeSlot = SlotMerged
    state.finishSourceTransition()
  true

proc closeIndexedSources*(state: var AppState) =
  for slot in SourceSlot:
    state.sourceViews[slot].close()

proc prepareIndexedSources*(state: var AppState, indexDir: string = "") =
  state.runtimeIndexDir =
    if indexDir.len > 0:
      indexDir
    else:
      defaultRuntimeIndexDir()
  for slot in SourceSlot:
    state.sourceViews[slot].close()
  let enabledKinds = state.enabledIndexKinds()
  discard prepareRuntimeIndexesAsync(state.runtimeIndexDir, enabledKinds)
  if state.explicitSourceSelection and state.enabledSlots.len > 1:
    state.baseSlot = SlotMerged
  else:
    state.baseSlot = sourceSlot(state.baseDataSource, state.baseSearchMode)
  state.activeSlot = state.baseSlot
  if state.ensureSlotViewLoaded(state.activeSlot):
    state.closeInactiveSourceViews({state.activeSlot})
    state.rebuildVisible()
    state.statusMessage = ""
  else:
    state.markIndexing()

proc switchToNimble*(state: var AppState): bool =
  if SlotNimble notin state.enabledSlots:
    return false
  if state.dataSource != SourceNimble or state.activeSlot != SlotNimble:
    state.resetSourceTransition()
    state.dataSource = SourceNimble
    state.activeSlot = SlotNimble
    state.finishSourceTransition()
  true

proc switchToSystem*(state: var AppState, mode: SearchMode): bool =
  let targetSlot = if mode == ModeAUR: SlotAur else: SlotSystem
  if targetSlot notin state.enabledSlots:
    return false
  if state.dataSource != SourceSystem or state.searchMode != mode or
      state.activeSlot != targetSlot:
    state.resetSourceTransition()
    state.dataSource = SourceSystem
    state.searchMode = mode
    state.activeSlot = targetSlot
    state.finishSourceTransition()
  true

proc restoreBaseState*(state: var AppState) =
  if state.baseSlot == SlotMerged:
    if state.activeSlot != SlotMerged or state.dataSource != state.baseDataSource or
        state.searchMode != state.baseSearchMode:
      state.resetSourceTransition()
      state.dataSource = state.baseDataSource
      state.searchMode = state.baseSearchMode
      state.activeSlot = SlotMerged
      state.finishSourceTransition()
  elif state.baseDataSource == SourceNimble:
    discard switchToNimble(state)
  else:
    discard switchToSystem(state, state.baseSearchMode)

proc pollIndexUpdates*(state: var AppState) =
  if (getMonoTime() - state.lastIndexPollTime).inMilliseconds() < 250:
    return
  state.lastIndexPollTime = getMonoTime()

  let path = state.slotIndexPath(state.activeSlot)
  let stamp = indexStamp(path)
  let activeValid = valid(addr state.sourceViews[state.activeSlot])
  if stamp <= 0:
    return
  if activeValid and stamp <= state.sourceIndexStamps[state.activeSlot]:
    return

  let validated = validateSourceIndex(path, deep = false)
  if not validated.valid:
    return

  try:
    let oldCursor = state.cursor
    var nextView = openValidatedSourceIndex(validated)
    state.sourceViews[state.activeSlot].close()
    state.sourceViews[state.activeSlot] = nextView
    state.sourceIndexStamps[state.activeSlot] = stamp
    state.detailGeneration.inc()
    clearDetailCache(state.detailsCache)
    state.rebuildVisible()
    if state.visibleCount() > 0:
      state.cursor = clamp(oldCursor, 0, state.visibleCount() - 1)
    else:
      state.cursor = 0
      state.scroll = 0
    state.wrappedDetails = @[]
    state.lastDetailIdx = -1
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.detailEnrichmentInFlight = false
    state.detailEnrichmentIdx = -1
    state.detailScramble.active = false
    state.statusMessage = ""
    state.indexRefreshInFlight = false
    state.needsRedraw = true
  except CatchableError:
    state.markIndexing()
