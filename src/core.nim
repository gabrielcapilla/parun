import std/[tables, strutils, monotimes, times]
import types, state, input, pkgManager, pUtils

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

        if effectiveQuery.len > 1 and result.searchMode != ModeAUR:
          result.searchId.inc()
          result.isSearching = true
          result.statusMessage = "Searching..."

          requestSearch(effectiveQuery, result.searchId)
        else:
          if result.searchMode != ModeAUR:
            result.visibleIndices.setLen(0)
            if result.searchMode == ModeAUR:
              result.statusMessage = "Type to search AUR..."
  of MsgSearchResults:
    if msg.searchId != result.searchId:
      return result
    result.statusMessage = ""

    if msg.isAppend:
      if result.dataSearchId != msg.searchId:
        result.soa.hot.locators.setLen(0)
        result.soa.hot.nameLens.setLen(0)
        result.soa.hot.nameHash.setLen(0)
        result.soa.cold.verLens.setLen(0)
        result.soa.cold.repoIndices.setLen(0)
        result.soa.cold.flags.setLen(0)
        result.textArena.setLen(0)
        result.repos.setLen(0)
        result.selectionBits.setLen(0)
        result.detailsCache.clear()
        result.dataSearchId = msg.searchId

      var repoMap = newSeq[uint8](msg.repos.len)
      var repoOffsetMap = newSeq[uint16](msg.repos.len)
      var repoLookup = initTable[string, uint8]()

      for i, r in msg.repos:
        if r in repoLookup:
          let foundIdx = repoLookup[r]
          repoMap[i] = foundIdx
          repoOffsetMap[i] = repoOffsetMap[foundIdx]
        else:
          repoLookup[r] = uint8(result.repos.len)
          repoMap[i] = uint8(result.repos.len)
          repoOffsetMap[i] = uint16(result.repoArena.len)
          result.repos.add(r)
          result.repoLens.add(uint8(r.len))
          for c in r:
            result.repoArena.add(c)

      let baseOffset = uint32(result.textArena.len)
      for c in msg.textChunk:
        result.textArena.add(c)

      for i in 0 ..< msg.soa.hot.locators.len:
        let absLoc = baseOffset + msg.soa.hot.locators[i]

        result.soa.hot.locators.add(absLoc)
        result.soa.hot.nameLens.add(msg.soa.hot.nameLens[i])
        result.soa.hot.nameHash.add(msg.soa.hot.nameHash[i])
        result.soa.cold.verLens.add(msg.soa.cold.verLens[i])
        result.soa.cold.repoIndices.add(repoMap[msg.soa.cold.repoIndices[i]])
        result.soa.cold.flags.add(msg.soa.cold.flags[i])
        result.repoOffsets.add(repoOffsetMap[msg.soa.cold.repoIndices[i]])

      let requiredWords = (result.soa.hot.locators.len + 63) div 64
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
      elif result.dataSource == SourceSystem and result.searchMode == ModeAUR:
        result.aurDB.soa = result.soa
        result.aurDB.textArena = result.textArena
        result.aurDB.repos = result.repos
        result.aurDB.isLoaded = true

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

      result.selectionBits.setLen((result.soa.hot.locators.len + 63) div 64)
      for i in 0 ..< result.selectionBits.len:
        result.selectionBits[i] = 0
      result.detailsCache.clear()

      result.repoArena.setLen(0)
      result.repoLens.setLen(0)
      result.repoOffsets.setLen(result.soa.hot.locators.len)

      var repoOffsetMap: array[256, uint16]
      for i in 0 ..< 256:
        repoOffsetMap[i] = 0xFFFF

      for i in 0 ..< result.soa.hot.locators.len:
        let repoIdx = int(result.soa.cold.repoIndices[i])
        if repoIdx < result.repos.len and repoOffsetMap[repoIdx] == 0xFFFF:
          repoOffsetMap[repoIdx] = uint16(result.repoArena.len)
          result.repoLens.add(uint8(result.repos[repoIdx].len))
          for c in result.repos[repoIdx]:
            result.repoArena.add(c)
        if repoIdx < 256:
          result.repoOffsets[i] = repoOffsetMap[repoIdx]
        else:
          result.repoOffsets[i] = 0

      if result.soa.hot.nameHash.len != result.soa.hot.locators.len:
        for i in 0 ..< result.soa.hot.locators.len:
          let nameStr = result.getName(i)
          result.soa.hot.nameHash.add(hashName(nameStr))

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
      elif result.dataSource == SourceSystem and result.searchMode == ModeAUR:
        result.aurDB.soa = result.soa
        result.aurDB.textArena = result.textArena
        result.aurDB.repos = result.repos
        result.aurDB.isLoaded = true

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
