import std/[sets, tables]
import types, state, input, pkgManager

proc processInput*(state: var AppState, k: char, listHeight: int) =
  if state.inputMode != ModeVimCommand:
    if k == KeyCtrlA:
      if state.dataSource == SourceSystem:
        if state.searchMode == ModeLocal:
          state.searchMode = ModeHybrid
        else:
          state.searchMode = ModeLocal
          if state.systemDB.isLoaded:
            state.pkgs = state.systemDB.pkgs
            state.textBlocks = state.systemDB.textBlocks
            state.repos = state.systemDB.repos
            state.visibleIndices = filterIndices(state, state.searchBuffer)
            state.cursor = 0
      return

    if k == KeyCtrlN:
      saveCurrentToDB(state)
      state.searchId.inc()
      state.visibleIndices = @[]
      state.selected = initHashSet[string]()
      state.cursor = 0
      state.scroll = 0
      state.detailsCache = initTable[string, string]()
      state.searchBuffer = ""
      state.searchCursor = 0

      if state.dataSource == SourceSystem:
        state.dataSource = SourceNimble
        loadFromDB(state, SourceNimble)
        if not state.nimbleDB.isLoaded:
          requestLoadNimble(state.searchId)
        else:
          state.visibleIndices = filterIndices(state, "")
      else:
        state.dataSource = SourceSystem
        state.searchMode = ModeLocal
        loadFromDB(state, SourceSystem)
        if not state.systemDB.isLoaded:
          requestLoadAll(state.searchId)
        else:
          state.visibleIndices = filterIndices(state, "")
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

proc update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(result, msg.key, listHeight)
  of MsgInputNew:
    processInput(result, msg.legacyKey, listHeight)
  of MsgSearchResults:
    if msg.searchId != result.searchId:
      return result

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

    result.isSearching = false
    result.justReceivedSearchResults = true
  of MsgDetailsLoaded:
    if result.detailsCache.len >= DetailsCacheLimit:
      result.detailsCache.clear()
    result.detailsCache[msg.pkgId] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
  of MsgTick:
    discard
