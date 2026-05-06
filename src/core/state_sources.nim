## Source-slot lifecycle and visible-list orchestration.
##
## Notes:
## - A `SourceSlot` maps to one validated/mapped immutable index view.
## - `prepareIndexedSources` is the bootstrap entrypoint used at startup.
## - `switchTo*` functions perform full state transitions (cursor, details cache,
##   visible list, and active mmap view).
import std/[monotimes, os, times]
import types
import ../storage/[index_builder, indexes]
import search_system, detail_cache

proc indexKindForSlot(slot: SourceSlot): IndexedSourceKind =
  case slot
  of SlotSystem: iskSystem
  of SlotAur: iskAur
  of SlotNimble: iskNimble
  of SlotMerged: iskSystem

proc modeForSlot*(slot: SourceSlot): tuple[source: DataSource, mode: SearchMode] =
  ## Converts runtime slot to logical `DataSource` + `SearchMode`.
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
    getLastModificationTime(path).toUnix()
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
      let merged = validateSourceIndex(mergedPath)
      if not merged.valid:
        scheduleIndexRefresh(runtimeDir, enabledKinds, mergedOnly = true)
        return false
      state.sourceViews[SlotMerged].close()
      state.sourceViews[SlotMerged] = openValidatedSourceIndex(merged)
      state.sourceIndexStamps[SlotMerged] = indexStamp(mergedPath)
      return true

    let validated = prepareRuntimeIndexesAsync(runtimeDir, {indexKindForSlot(slot)})
    if validated.len == 0 or not validated[0].valid:
      return false
    state.sourceViews[slot].close()
    state.sourceViews[slot] = openValidatedSourceIndex(validated[0])
    state.sourceIndexStamps[slot] = indexStamp(validated[0].path)
    true
  except CatchableError:
    false

proc closeInactiveSourceViews(state: var AppState, keep: set[SourceSlot]) =
  for slot in SourceSlot:
    if slot notin keep:
      state.sourceViews[slot].close()

proc activeView*(state: var AppState): ptr SourceIndexView {.inline.} =
  ## Returns pointer to currently active mapped source index.
  addr state.sourceViews[state.activeSlot]

proc currentPackageCount*(state: var AppState): int {.inline.} =
  ## Package count of active source (O(1)).
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
  ## Clears materialized visible list and disables identity mode.
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
  state.wrappedDetails = @[]
  state.pendingDetailIdx = -1
  state.detailScramble.active = false
  state.detailRequestInFlight = false
  state.searchId.inc()
  state.cursor = 0
  state.scroll = 0

proc syncSelectionCapacity(state: var AppState) =
  let requiredWords = (state.currentPackageCount() + 63) div 64
  if state.selectionBits.len > requiredWords:
    state.selectionBits.setLen(requiredWords)

proc rebuildVisible*(state: var AppState)

proc finishSourceTransition(state: var AppState) =
  if state.ensureSlotViewLoaded(state.activeSlot):
    state.syncSelectionCapacity()
    state.closeInactiveSourceViews({state.activeSlot})
    state.rebuildVisible()
    state.statusMessage = ""
    state.indexRefreshInFlight = false
  else:
    state.markIndexing()

proc rebuildVisible*(state: var AppState) =
  ## Recomputes visible list from current mode/query.
  if state.viewingSelection:
    filterBySelection(state.selectedPackages, state.activeView, state.visibleIndices)
    state.visibleAll = false
    state.visibleAllCount = 0
  else:
    filterIndices(
      state.searchBuffer,
      state.activeView,
      state.visibleIndices,
      state.visibleAll,
      state.visibleAllCount,
      addr state.perf,
    )

proc switchToMerged*(state: var AppState): bool =
  ## Switches active state to the combined enabled source view.
  if state.enabledSlots.len <= 1:
    return true
  if state.activeSlot != SlotMerged:
    state.resetSourceTransition()
    state.dataSource = SourceSystem
    state.searchMode = ModeLocal
    state.activeSlot = SlotMerged
    state.finishSourceTransition()
  true

proc activateCurrentSource*(state: var AppState) =
  ## Aligns `activeSlot` with current source/mode and ensures index is loaded.
  state.activeSlot = sourceSlot(state.dataSource, state.searchMode)
  discard state.ensureSlotViewLoaded(state.activeSlot)
  state.syncSelectionCapacity()

proc closeIndexedSources*(state: var AppState) =
  ## Closes all mapped source views.
  for slot in SourceSlot:
    state.sourceViews[slot].close()

proc prepareIndexedSources*(state: var AppState, indexDir: string = "") =
  ## Startup bootstrap for runtime indexes.
  ##
  ## Behavior:
  ## - chooses runtime index directory
  ## - ensures needed source indexes exist/validate
  ## - selects merged slot when explicit multi-source mode is active
  ## - builds initial visible list
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
    state.activeSlot = SlotMerged
    if state.ensureSlotViewLoaded(SlotMerged):
      state.syncSelectionCapacity()
      state.closeInactiveSourceViews({state.activeSlot})
      state.rebuildVisible()
      state.statusMessage = ""
    else:
      state.markIndexing()
  else:
    state.baseSlot = sourceSlot(state.baseDataSource, state.baseSearchMode)
    state.activeSlot = state.baseSlot
    if state.ensureSlotViewLoaded(state.activeSlot):
      state.syncSelectionCapacity()
      state.closeInactiveSourceViews({state.activeSlot})
      state.rebuildVisible()
      state.statusMessage = ""
    else:
      state.markIndexing()

proc switchToNimble*(state: var AppState): bool =
  ## Switches active state to Nimble source slot.
  if SlotNimble notin state.enabledSlots:
    return false
  if state.dataSource != SourceNimble or state.activeSlot != SlotNimble:
    state.resetSourceTransition()
    state.dataSource = SourceNimble
    state.activeSlot = SlotNimble
    state.finishSourceTransition()
  true

proc switchToSystem*(state: var AppState, mode: SearchMode): bool =
  ## Switches active state to local or AUR system slot.
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
  ## Restores source/mode selected as startup baseline.
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
  ## Cheap active-view refresh poll. Swaps mmap only after a valid index lands.
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

  let validated = validateSourceIndex(path)
  if not validated.valid:
    return

  try:
    let oldCursor = state.cursor
    state.sourceViews[state.activeSlot].close()
    state.sourceViews[state.activeSlot] = openValidatedSourceIndex(validated)
    state.sourceIndexStamps[state.activeSlot] = stamp
    state.syncSelectionCapacity()
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
    state.detailScramble.active = false
    state.statusMessage = ""
    state.indexRefreshInFlight = false
    state.needsRedraw = true
  except CatchableError:
    state.markIndexing()
