import std/[tables, monotimes, times]
import ../types, search_system, navigation_system, input_system
import ../../pkgs/manager

proc appendBatch*(db: var PackageDB, msg: Msg) =
  let batchLen = msg.soa.hot.locators.len
  var repoMap = newSeq[uint8](msg.repos.len)
  var dbRepoLookup = initTable[string, uint8](db.repos.len + msg.repos.len)
  for i, r in db.repos:
    dbRepoLookup[r] = uint8(i)

  for i, r in msg.repos:
    if r in dbRepoLookup:
      repoMap[i] = dbRepoLookup[r]
    else:
      let rIdx = uint8(db.repos.len)
      db.repos.add(r)
      let offset = uint16(db.repoArena.len)
      db.repoOffsets.add(offset)
      db.repoLens.add(uint8(r.len))
      let oldLen = db.repoArena.len
      db.repoArena.setLen(oldLen + r.len)
      if r.len > 0:
        copyMem(addr db.repoArena[oldLen], unsafeAddr r[0], r.len)
      repoMap[i] = rIdx
      dbRepoLookup[r] = rIdx

  let textBase = uint32(db.textArena.len)
  db.soa.hot.locators.setLen(db.soa.hot.locators.len + batchLen)
  db.soa.hot.nameLens.setLen(db.soa.hot.nameLens.len + batchLen)
  db.soa.hot.flags.setLen(db.soa.hot.flags.len + batchLen)
  db.soa.cold.verLens.setLen(db.soa.cold.verLens.len + batchLen)
  db.soa.cold.repoIndices.setLen(db.soa.cold.repoIndices.len + batchLen)

  let oldLen = db.soa.hot.locators.len - batchLen
  for i in 0 ..< batchLen:
    db.soa.hot.locators[oldLen + i] = textBase + msg.soa.hot.locators[i]
    db.soa.hot.nameLens[oldLen + i] = msg.soa.hot.nameLens[i]
    db.soa.hot.flags[oldLen + i] = msg.soa.hot.flags[i]
    db.soa.cold.verLens[oldLen + i] = msg.soa.cold.verLens[i]
    let batchRIdx = msg.soa.cold.repoIndices[i]
    if batchRIdx < repoMap.len.uint8:
      db.soa.cold.repoIndices[oldLen + i] = repoMap[batchRIdx]
    else:
      db.soa.cold.repoIndices[oldLen + i] = 0

  for c in msg.textChunk:
    db.textArena.add(c)

proc handleSearchResults*(state: var AppState, msg: Msg, listHeight: int) =
  let isBackground =
    (msg.reqSource != state.dataSource) or
    (msg.reqSource == SourceSystem and msg.reqMode != state.searchMode)

  if isBackground:
    if msg.reqSource == SourceNimble:
      appendBatch(state.nimbleDB, msg)
      state.nimbleDB.isLoaded = true
    elif msg.reqSource == SourceSystem and msg.reqMode == ModeAUR:
      appendBatch(state.aurDB, msg)
      state.aurDB.isLoaded = true
    return

  if msg.searchId != state.searchId:
    return
  state.statusMessage = ""

  if msg.isAppend:
    if state.dataSearchId != msg.searchId:
      state.soa.hot.locators.setLen(0)
      state.soa.hot.nameLens.setLen(0)
      state.soa.hot.flags.setLen(0)
      state.soa.cold.verLens.setLen(0)
      state.soa.cold.repoIndices.setLen(0)
      state.textArena.setLen(0)
      state.repos.setLen(0)
      state.repoArena.setLen(0)
      state.repoLens.setLen(0)
      state.repoOffsets.setLen(0)
      state.selectionBits.setLen(0)
      state.detailsCache.clear()
      state.dataSearchId = msg.searchId

    var repoMap = newSeq[uint8](msg.repos.len)
    var repoLookup = initTable[string, uint8](state.repos.len + msg.repos.len)
    for i, r in state.repos:
      repoLookup[r] = uint8(i)

    for i, r in msg.repos:
      if r in repoLookup:
        repoMap[i] = repoLookup[r]
      else:
        let rIdx = uint8(state.repos.len)
        repoLookup[r] = rIdx
        repoMap[i] = rIdx
        state.repoOffsets.add(uint16(state.repoArena.len))
        state.repos.add(r)
        state.repoLens.add(uint8(r.len))
        let oldLen = state.repoArena.len
        state.repoArena.setLen(oldLen + r.len)
        if r.len > 0:
          copyMem(addr state.repoArena[oldLen], unsafeAddr r[0], r.len)

    let baseOffset = uint32(state.textArena.len)
    for c in msg.textChunk:
      state.textArena.add(c)

    let batchLen = msg.soa.hot.locators.len
    let oldLen = state.soa.hot.locators.len
    state.soa.hot.locators.setLen(oldLen + batchLen)
    state.soa.hot.nameLens.setLen(oldLen + batchLen)
    state.soa.hot.flags.setLen(oldLen + batchLen)
    state.soa.cold.verLens.setLen(oldLen + batchLen)
    state.soa.cold.repoIndices.setLen(oldLen + batchLen)

    for i in 0 ..< batchLen:
      let absLoc = baseOffset + msg.soa.hot.locators[i]
      state.soa.hot.locators[oldLen + i] = absLoc
      state.soa.hot.nameLens[oldLen + i] = msg.soa.hot.nameLens[i]
      state.soa.hot.flags[oldLen + i] = msg.soa.hot.flags[i]
      state.soa.cold.verLens[oldLen + i] = msg.soa.cold.verLens[i]
      state.soa.cold.repoIndices[oldLen + i] = repoMap[msg.soa.cold.repoIndices[i]]

    let requiredWords = (state.soa.hot.locators.len + 63) div 64
    if state.selectionBits.len < requiredWords:
      state.selectionBits.setLen(requiredWords)

    if state.dataSource == SourceSystem and state.searchMode == ModeLocal:
      state.systemDB.soa = state.soa
      state.systemDB.textArena = state.textArena
      state.systemDB.repos = state.repos
      state.systemDB.isLoaded = true
    elif state.dataSource == SourceNimble:
      state.nimbleDB.soa = state.soa
      state.nimbleDB.textArena = state.textArena
      state.nimbleDB.repos = state.repos
      state.nimbleDB.isLoaded = true
    elif state.dataSource == SourceSystem and state.searchMode == ModeAUR:
      state.aurDB.soa = state.soa
      state.aurDB.textArena = state.textArena
      state.aurDB.repos = state.repos
      state.aurDB.isLoaded = true

    if not state.viewingSelection:
      filterIndices(state, state.searchBuffer, state.visibleIndices)
    updateNavigation(state, listHeight)
  else:
    # Handle non-append case (replace all)
    state.soa = msg.soa
    state.textArena = newSeqOfCap[char](msg.textChunk.len)
    for c in msg.textChunk:
      state.textArena.add(c)
    state.repos = msg.repos
    state.dataSearchId = msg.searchId
    state.selectionBits.setLen((state.soa.hot.locators.len + 63) div 64)
    for i in 0 ..< state.selectionBits.len:
      state.selectionBits[i] = 0
    state.detailsCache.clear()
    state.repoArena.setLen(0)
    state.repoLens.setLen(0)
    state.repoOffsets.setLen(0)
    for r in state.repos:
      state.repoOffsets.add(uint16(state.repoArena.len))
      state.repoLens.add(uint8(r.len))
      for c in r:
        state.repoArena.add(c)

    # Update background DBs
    if state.dataSource == SourceSystem and state.searchMode == ModeLocal:
      state.systemDB.soa = state.soa
      state.systemDB.textArena = state.textArena
      state.systemDB.repos = state.repos
      state.systemDB.isLoaded = true
    elif state.dataSource == SourceNimble:
      state.nimbleDB.soa = state.soa
      state.nimbleDB.textArena = state.textArena
      state.nimbleDB.repos = state.repos
      state.nimbleDB.isLoaded = true
    elif state.dataSource == SourceSystem and state.searchMode == ModeAUR:
      state.aurDB.soa = state.soa
      state.aurDB.textArena = state.textArena
      state.aurDB.repos = state.repos
      state.aurDB.isLoaded = true

    if not state.viewingSelection:
      filterIndices(state, state.searchBuffer, state.visibleIndices)
    state.cursor = 0
    state.scroll = 0

  state.isSearching = false
  state.justReceivedSearchResults = true

proc update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(result, msg.key, listHeight)
  of MsgTick:
    if result.debouncePending:
      if (getMonoTime() - result.lastInputTime).inMilliseconds() > 500:
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
    handleSearchResults(result, msg, listHeight)
  of MsgDetailsLoaded:
    if result.detailsCache.len >= DetailsCacheLimit:
      result.detailsCache.clear()
    result.detailsCache[msg.pkgIdx] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
    result.statusMessage = "Error"
