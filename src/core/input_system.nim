## Input orchestration layer.
##
## Notes:
## - `input_handler` edits cursor/text/selection toggles.
## - This module additionally decides source switching based on prefixes:
##   `aur/` -> SlotAur, `nim*/` -> SlotNimble, otherwise base source.
## - It then triggers hot-path filtering and status-message updates.
import std/[monotimes, strutils]
import types, state, input_handler
import search_system
import ../storage/indexes

## Consumes one key and updates derived search/source state.
##
## This is the highest-level input reducer used by the UI tick loop.
proc processInput*(state: var AppState, k: char, listHeight: int) =
  if k == KeyCtrlS:
    state.viewingSelection = not state.viewingSelection
    state.cursor = 0
    state.scroll = 0
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
    return

  if k == KeyF1:
    state.showDetails = not state.showDetails
    return

  handleInput(state, k, listHeight)
  state.lastInputTime = getMonoTime()

  if not state.viewingSelection:
    var blockedSwitch = false
    let isNimbleQuery =
      state.searchBuffer.startsWith("nimble/") or state.searchBuffer.startsWith("nim/") or
      state.searchBuffer.startsWith("n/")
    let isAurQuery =
      state.searchBuffer.startsWith("aur/") or state.searchBuffer.startsWith("a/")
    let isInstalledQuery =
      state.searchBuffer.startsWith("installed/") or state.searchBuffer.startsWith("i/")

    if isInstalledQuery:
      blockedSwitch = not switchToMerged(state)
      if blockedSwitch:
        state.statusMessage = "Combined index unavailable"
    elif isNimbleQuery:
      blockedSwitch = not switchToNimble(state)
      if blockedSwitch:
        if SlotNimble in state.enabledSlots:
          state.statusMessage = "Nimble index unavailable"
        else:
          state.statusMessage = "Nimble source disabled (enable with --nimble)"
    elif isAurQuery:
      if state.activeSlot != SlotAur or state.dataSource != SourceSystem or
          state.searchMode != ModeAUR:
        blockedSwitch = not switchToSystem(state, ModeAUR)
        if blockedSwitch:
          if SlotAur in state.enabledSlots:
            state.statusMessage = "AUR index unavailable"
          else:
            state.statusMessage = "AUR source disabled (enable with --aur)"
    else:
      if state.activeSlot != state.baseSlot or state.dataSource != state.baseDataSource or
          state.searchMode != state.baseSearchMode:
        restoreBaseState(state)

    if blockedSwitch:
      state.clearVisible()
    elif not valid(state.activeView):
      state.clearVisible()
      state.statusMessage = "Indexing..."
      state.indexRefreshInFlight = true
    else:
      filterIndices(
        state.searchBuffer,
        state.activeView,
        state.visibleIndices,
        state.visibleAll,
        state.visibleAllCount,
        addr state.perf,
      )
      state.statusMessage = ""
    state.debouncePending = false
