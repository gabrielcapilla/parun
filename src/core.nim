import std/[tables, strutils, monotimes, times]
import types, state, input, pkgManager

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
      state.searchBuffer.startsWith("nimble/") or state.searchBuffer.startsWith("nim/")
    let isAurQuery = state.searchBuffer.startsWith("aur/")

    if isNimbleQuery:
      switchToNimble(state)
      state.debouncePending = false
    elif isAurQuery:
      if state.dataSource != SourceSystem:
        switchToSystem(state, ModeAUR)
      else:
        if state.searchMode != ModeAUR:
          switchToSystem(state, ModeAUR)
      state.debouncePending = true
    else:
      if state.dataSource != state.baseDataSource:
        restoreBaseState(state)
      elif state.dataSource == SourceSystem and state.searchMode != state.baseSearchMode:
        restoreBaseState(state)

      filterIndices(state, state.searchBuffer, state.visibleIndices)
      state.debouncePending = false
      state.statusMessage = ""

proc update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(result, msg.key, listHeight)
  of MsgTick:
    if result.debouncePending:
      if (getMonoTime() - result.lastInputTime).inMilliseconds > 500:
        result.debouncePending = false
        let effectiveQuery = getEffectiveQuery(result.searchBuffer)

        if effectiveQuery.len > 1:
          result.searchId.inc()
          result.isSearching = true
          result.statusMessage = "Searching AUR..."

          var queryToSend = effectiveQuery
          if result.searchMode == ModeAUR:
            queryToSend = "aur/" & effectiveQuery

          requestSearch(queryToSend, result.searchId)
        else:
          result.visibleIndices.setLen(0)
          result.statusMessage = "Type to search AUR..."
  of MsgSearchResults:
    if msg.searchId != result.searchId:
      return result
    result.statusMessage = ""

    if msg.isAppend:
      if result.dataSearchId != msg.searchId:
        result.soa.locators.setLen(0)
        result.soa.nameLens.setLen(0)
        result.soa.verLens.setLen(0)
        result.soa.repoIndices.setLen(0)
        result.soa.flags.setLen(0)
        result.textArena.setLen(0)
        result.repos.setLen(0)
        result.selectionBits.setLen(0)
        result.detailsCache.clear()
        result.dataSearchId = msg.searchId

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

      let baseOffset = uint32(result.textArena.len)
      for c in msg.textChunk:
        result.textArena.add(c)

      for i in 0 ..< msg.soa.locators.len:
        let absLoc = baseOffset + msg.soa.locators[i]

        result.soa.locators.add(absLoc)
        result.soa.nameLens.add(msg.soa.nameLens[i])
        result.soa.verLens.add(msg.soa.verLens[i])
        result.soa.repoIndices.add(repoMap[msg.soa.repoIndices[i]])
        result.soa.flags.add(msg.soa.flags[i])

      let requiredWords = (result.soa.locators.len + 63) div 64
      if result.selectionBits.len < requiredWords:
        result.selectionBits.setLen(requiredWords)

      if result.dataSource == SourceSystem and result.searchMode == ModeLocal:
        result.systemDB.soa = result.soa
        result.systemDB.textArena = result.textArena
        result.systemDB.repos = result.repos
        result.systemDB.isLoaded = true
      elif result.dataSource == SourceNimble:
        result.nimbleDB.soa = result.soa
        result.nimbleDB.textArena = result.textArena
        result.nimbleDB.repos = result.repos
        result.nimbleDB.isLoaded = true

      if not result.viewingSelection:
        filterIndices(result, result.searchBuffer, result.visibleIndices)

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
      result.soa = msg.soa
      result.textArena = newSeqOfCap[char](msg.textChunk.len)
      for c in msg.textChunk:
        result.textArena.add(c)

      result.repos = msg.repos
      result.dataSearchId = msg.searchId

      result.selectionBits.setLen((result.soa.locators.len + 63) div 64)
      for i in 0 ..< result.selectionBits.len:
        result.selectionBits[i] = 0
      result.detailsCache.clear()

      if result.dataSource == SourceSystem and result.searchMode == ModeLocal:
        result.systemDB.soa = result.soa
        result.systemDB.textArena = result.textArena
        result.systemDB.repos = result.repos
        result.systemDB.isLoaded = true
      elif result.dataSource == SourceNimble:
        result.nimbleDB.soa = result.soa
        result.nimbleDB.textArena = result.textArena
        result.nimbleDB.repos = result.repos
        result.nimbleDB.isLoaded = true

      if not result.viewingSelection:
        filterIndices(result, result.searchBuffer, result.visibleIndices)
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
    result.detailsCache[msg.pkgIdx] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
    result.statusMessage = "Error"
