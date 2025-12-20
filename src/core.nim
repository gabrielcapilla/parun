import std/[sets, tables, strutils, monotimes, times]
import types, state, input, pkgManager

proc switchToNimble(state: var AppState) =
  if state.dataSource != SourceNimble:
    state.visibleIndices = @[]
    saveCurrentToDB(state)
    state.dataSource = SourceNimble
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selected.clear()

    loadFromDB(state, SourceNimble)
    if not state.nimbleDB.isLoaded:
      requestLoadNimble(state.searchId)
    else:
      state.visibleIndices = filterIndices(state, state.searchBuffer)

proc switchToSystem(state: var AppState, mode: SearchMode) =
  if state.dataSource != SourceSystem or state.searchMode != mode:
    state.visibleIndices = @[]
    saveCurrentToDB(state)
    state.dataSource = SourceSystem
    state.searchMode = mode
    state.searchId.inc()
    state.cursor = 0
    state.scroll = 0
    state.selected.clear()

    loadFromDB(state, SourceSystem)
    if not state.systemDB.isLoaded:
      requestLoadAll(state.searchId)
    else:
      state.visibleIndices = filterIndices(state, state.searchBuffer)

proc restoreBaseState(state: var AppState) =
  if state.baseDataSource == SourceNimble:
    switchToNimble(state)
  else:
    switchToSystem(state, state.baseSearchMode)

proc processInput*(state: var AppState, k: char, listHeight: int) =
  if state.inputMode != ModeVimCommand:
    if k == KeyCtrlA:
      if state.dataSource == SourceSystem:
        if state.baseSearchMode == ModeLocal:
          state.baseSearchMode = ModeHybrid
        else:
          state.baseSearchMode = ModeLocal

        if not (
          state.searchBuffer.startsWith("aur/") or
          state.searchBuffer.startsWith("nimble/") or
          state.searchBuffer.startsWith("nim/")
        ):
          switchToSystem(state, state.baseSearchMode)
      return

    if k == KeyCtrlN:
      if state.baseDataSource == SourceSystem:
        state.baseDataSource = SourceNimble
      else:
        state.baseDataSource = SourceSystem
        state.baseSearchMode = ModeLocal

      restoreBaseState(state)
      return

    if k == KeyCtrlS:
      state.viewingSelection = not state.viewingSelection
      state.cursor = 0
      state.scroll = 0
      if state.viewingSelection:
        state.visibleIndices = filterBySelection(state)
      else:
        state.visibleIndices = filterIndices(state, state.searchBuffer)
      return

    if k == KeyF1:
      state.showDetails = not state.showDetails
      return

  handleInput(state, k, listHeight)
  state.lastInputTime = getMonoTime()

  if not state.viewingSelection:
    let isNimbleQuery =
      state.searchBuffer.startsWith("nimble/") or state.searchBuffer.startsWith("nim/")
    let isAurQuery = state.searchBuffer.startsWith("aur/")

    if isNimbleQuery:
      switchToNimble(state)
      state.debouncePending = false
    elif isAurQuery:
      if state.dataSource != SourceSystem:
        switchToSystem(state, ModeHybrid)
      else:
        state.searchMode = ModeHybrid

      state.debouncePending = true
      state.statusMessage = "Waiting..."
    else:
      if state.dataSource != state.baseDataSource:
        restoreBaseState(state)
      elif state.dataSource == SourceSystem and state.searchMode != state.baseSearchMode:
        restoreBaseState(state)

      state.visibleIndices = filterIndices(state, state.searchBuffer)
      state.debouncePending = false
      state.statusMessage = ""

proc update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(result, msg.key, listHeight)
  of MsgInputNew:
    processInput(result, msg.legacyKey, listHeight)
  of MsgTick:
    if result.debouncePending:
      let now = getMonoTime()
      if (now - result.lastInputTime).inMilliseconds > 500:
        result.debouncePending = false
        let effectiveQuery = getEffectiveQuery(result.searchBuffer)
        if effectiveQuery.len > 1:
          result.searchId.inc()
          result.isSearching = true
          result.statusMessage = "Searching AUR..."
          requestSearch(effectiveQuery, result.searchId)
        else:
          result.visibleIndices = @[]
          result.statusMessage = "Type to search AUR..."
  of MsgSearchResults:
    if msg.searchId != result.searchId:
      return result

    result.statusMessage = ""
    if msg.isAppend:
      var repoMap = newSeq[uint8](msg.repos.len)
      for i, r in msg.repos:
        var found = -1
        for j, existing in result.repos:
          if existing == r:
            found = j
            break
        if found == -1:
          repoMap[i] = uint8(result.repos.len)
          result.repos.add(r)
        else:
          repoMap[i] = uint8(found)

      let blockIdx = uint16(result.textBlocks.len)
      result.textBlocks.add(msg.textBlock)

      for p in msg.pkgs:
        var newP = p
        newP.blockIdx = blockIdx
        newP.repoIdx = repoMap[p.repoIdx]
        result.pkgs.add(newP)

      if result.dataSource == SourceSystem and result.searchMode == ModeLocal:
        result.systemDB.pkgs = result.pkgs
        result.systemDB.textBlocks = result.textBlocks
        result.systemDB.repos = result.repos
        result.systemDB.isLoaded = true
      elif result.dataSource == SourceNimble:
        result.nimbleDB.pkgs = result.pkgs
        result.nimbleDB.textBlocks = result.textBlocks
        result.nimbleDB.repos = result.repos
        result.nimbleDB.isLoaded = true

      if not result.viewingSelection:
        result.visibleIndices = filterIndices(result, result.searchBuffer)

      if result.visibleIndices.len > 0:
        result.cursor = clamp(result.cursor, 0, result.visibleIndices.len - 1)
        if result.cursor < result.scroll:
          result.scroll = result.cursor
        elif result.cursor >= result.scroll + listHeight:
          result.scroll = result.cursor - listHeight + 1
      else:
        result.cursor = 0
        result.scroll = 0
        if result.dataSource == SourceNimble and result.searchBuffer.len > 0:
          result.statusMessage = "No results in Nimble"
    else:
      result.pkgs = msg.pkgs
      result.textBlocks = @[msg.textBlock]
      result.repos = msg.repos

      if result.dataSource == SourceSystem and result.searchMode == ModeLocal:
        result.systemDB.pkgs = result.pkgs
        result.systemDB.textBlocks = result.textBlocks
        result.systemDB.repos = result.repos
        result.systemDB.isLoaded = true
      elif result.dataSource == SourceNimble:
        result.nimbleDB.pkgs = result.pkgs
        result.nimbleDB.textBlocks = result.textBlocks
        result.nimbleDB.repos = result.repos
        result.nimbleDB.isLoaded = true

      if not result.viewingSelection:
        result.visibleIndices = filterIndices(result, result.searchBuffer)

      result.cursor = 0
      result.scroll = 0

      if result.visibleIndices.len == 0 and result.dataSource == SourceNimble and
          result.searchBuffer.len > 0:
        result.statusMessage = "No results in Nimble"

    result.isSearching = false
    result.justReceivedSearchResults = true
  of MsgDetailsLoaded:
    if result.detailsCache.len >= DetailsCacheLimit:
      result.detailsCache.clear()
    result.detailsCache[msg.pkgId] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
    result.statusMessage = "Error"
