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
      discard ensureRuntimeIndexes(runtimeDir, enabledKinds)
      let mergedPath = ensureMergedRuntimeIndex(runtimeDir, enabledKinds)
      let merged = validateSourceIndex(mergedPath)
      if not merged.valid:
        return false
      state.sourceViews[SlotMerged].close()
      state.sourceViews[SlotMerged] = openValidatedSourceIndex(merged)
      return true

    let validated = ensureRuntimeIndexes(runtimeDir, {indexKindForSlot(slot)})
    if validated.len == 0 or not validated[0].valid:
      return false
    state.sourceViews[slot].close()
    state.sourceViews[slot] = openValidatedSourceIndex(validated[0])
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

proc rebuildVisible*(state: var AppState) =
  if state.viewingSelection:
    filterBySelection(
      state.selectionBits, state.currentPackageCount(), state.visibleIndices
    )
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

proc syncSelectionCapacity(state: var AppState) =
  let requiredWords = (state.currentPackageCount() + 63) div 64
  if state.selectionBits.len > requiredWords:
    state.selectionBits.setLen(requiredWords)

proc activateCurrentSource*(state: var AppState) =
  state.activeSlot = sourceSlot(state.dataSource, state.searchMode)
  discard state.ensureSlotViewLoaded(state.activeSlot)
  state.syncSelectionCapacity()

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
  if state.explicitSourceSelection and state.enabledSlots.len > 1:
    discard ensureRuntimeIndexes(state.runtimeIndexDir, enabledKinds)
    if not state.ensureSlotViewLoaded(SlotMerged):
      raise newException(IOError, "failed to prepare merged runtime index")
    state.baseSlot = SlotMerged
    state.activeSlot = SlotMerged
    state.syncSelectionCapacity()
  else:
    state.baseSlot = sourceSlot(state.baseDataSource, state.baseSearchMode)
    let baseKind = indexKindForSlot(state.baseSlot)
    discard ensureRuntimeIndexes(state.runtimeIndexDir, {baseKind})
    state.activateCurrentSource()
  state.closeInactiveSourceViews({state.activeSlot})
  state.rebuildVisible()

proc switchToNimble*(state: var AppState): bool =
  if SlotNimble notin state.enabledSlots:
    return false
  if state.dataSource != SourceNimble or state.activeSlot != SlotNimble:
    if not state.ensureSlotViewLoaded(SlotNimble):
      return false
    state.clearVisible()
    clearDetailCache(state.detailsCache)
    state.wrappedDetails = @[]
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.dataSource = SourceNimble
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    state.activateCurrentSource()
    state.closeInactiveSourceViews({state.activeSlot})
    state.rebuildVisible()
  true

proc switchToSystem*(state: var AppState, mode: SearchMode): bool =
  let targetSlot = if mode == ModeAUR: SlotAur else: SlotSystem
  if targetSlot notin state.enabledSlots:
    return false
  if state.dataSource != SourceSystem or state.searchMode != mode or
      state.activeSlot != targetSlot:
    if not state.ensureSlotViewLoaded(targetSlot):
      return false
    state.clearVisible()
    clearDetailCache(state.detailsCache)
    state.wrappedDetails = @[]
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.dataSource = SourceSystem
    state.searchMode = mode
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selectionBits.setLen(0)
    state.activateCurrentSource()
    state.closeInactiveSourceViews({state.activeSlot})
    state.rebuildVisible()
  true

proc restoreBaseState*(state: var AppState) =
  if state.baseSlot == SlotMerged:
    if state.activeSlot != SlotMerged or state.dataSource != state.baseDataSource or
        state.searchMode != state.baseSearchMode:
      if not state.ensureSlotViewLoaded(SlotMerged):
        return
      state.clearVisible()
      clearDetailCache(state.detailsCache)
      state.wrappedDetails = @[]
      state.pendingDetailIdx = -1
      state.detailRequestInFlight = false
      state.dataSource = state.baseDataSource
      state.searchMode = state.baseSearchMode
      state.searchId.inc()
      state.cursor = 0
      state.scroll = 0
      state.selectionBits.setLen(0)
      state.activeSlot = SlotMerged
      state.syncSelectionCapacity()
      state.closeInactiveSourceViews({state.activeSlot})
      state.rebuildVisible()
  elif state.baseDataSource == SourceNimble:
    discard switchToNimble(state)
  else:
    discard switchToSystem(state, state.baseSearchMode)
