import std/[monotimes, strutils]
import ../catalog/[model, state]
import input_handler
import ../index/indexes

proc processInput*(state: var AppState, k: char, listHeight: int) =
  if k == KeyCtrlS:
    state.viewingSelection = not state.viewingSelection
    state.cursor = 0
    state.scroll = 0
    state.rebuildVisible()
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
      state.rebuildVisible()
    state.debouncePending = false
