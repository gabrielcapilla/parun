import std/[monotimes, strutils]
import ../[types, state, input_handler]
import search_system

proc processInput*(state: var AppState, k: char, listHeight: int) =
  if k == KeyCtrlS:
    state.viewingSelection = not state.viewingSelection
    state.cursor = 0
    state.scroll = 0
    if state.viewingSelection:
      filterBySelection(state, state.visibleIndices)
    else:
      filterIndices(state, state.searchBuffer, state.visibleIndices)
    return

  if k == KeyF1:
    state.showDetails = not state.showDetails
    return

  handleInput(state, k, listHeight)
  state.lastInputTime = getMonoTime()

  if not state.viewingSelection:
    let isNimbleQuery =
      state.searchBuffer.startsWith("nimble/") or state.searchBuffer.startsWith("nim/") or
      state.searchBuffer.startsWith("n/")
    let isAurQuery =
      state.searchBuffer.startsWith("aur/") or state.searchBuffer.startsWith("a/")

    if isNimbleQuery:
      switchToNimble(state)
    elif isAurQuery:
      if state.dataSource != SourceSystem or state.searchMode != ModeAUR:
        switchToSystem(state, ModeAUR)
    else:
      if state.dataSource != state.baseDataSource:
        restoreBaseState(state)
      elif state.dataSource == SourceSystem and state.searchMode != state.baseSearchMode:
        restoreBaseState(state)

    filterIndices(state, state.searchBuffer, state.visibleIndices)
    state.debouncePending = false
    state.statusMessage = ""
