import std/[tables, monotimes, times]
import ../types, search_system, navigation_system, input_system

proc appendChars(dst: var seq[char], src: string) {.inline.} =
  let srcLen = src.len
  if srcLen == 0:
    return
  let oldLen = dst.len
  dst.setLen(oldLen + srcLen)
  copyMem(addr dst[oldLen], unsafeAddr src[0], srcLen)

proc syncActiveDb(state: var AppState) =
  let db =
    case state.dataSource
    of SourceSystem:
      (if state.searchMode == ModeLocal: addr state.systemDB
      else: addr state.aurDB)
    of SourceNimble:
      addr state.nimbleDB
  db[].soa = state.soa
  db[].textArena = state.textArena
  db[].repos = state.repos
  db[].repoArena = state.repoArena
  db[].repoLens = state.repoLens
  db[].repoOffsets = state.repoOffsets
  db[].isLoaded = true

proc appendBatch*(db: var PackageDB, msg: var Msg) =
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
      appendChars(db.repoArena, r)
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

  appendChars(db.textArena, msg.textChunk)

proc handleSearchResults*(state: var AppState, msg: var Msg, listHeight: int) =
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
        appendChars(state.repoArena, r)

    let baseOffset = uint32(state.textArena.len)
    appendChars(state.textArena, msg.textChunk)

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

    syncActiveDb(state)

    if not state.viewingSelection:
      filterIndices(state.searchBuffer, state.soa, state.textArena, state.visibleIndices)
    updateNavigation(state, listHeight)
  else:
    # Handle non-append case (replace all)
    state.soa = msg.soa
    state.textArena.setLen(0)
    appendChars(state.textArena, msg.textChunk)
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
      appendChars(state.repoArena, r)

    syncActiveDb(state)

    if not state.viewingSelection:
      filterIndices(state.searchBuffer, state.soa, state.textArena, state.visibleIndices)
    state.cursor = 0
    state.scroll = 0

  state.isSearching = false
  state.justReceivedSearchResults = true

proc update*(state: var AppState, msg: var Msg, listHeight: int) =
  state.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(state, msg.key, listHeight)
  of MsgTick:
    if state.debouncePending:
      if (getMonoTime() - state.lastInputTime).inMilliseconds() > 500:
        state.debouncePending = false
        let effectiveQuery = getEffectiveQuery(state.searchBuffer)
        if effectiveQuery.len > 1 and state.searchMode != ModeAUR:
          state.searchId.inc()
          state.isSearching = true
          state.statusMessage = "Searching..."
          requestSearch(effectiveQuery, state.searchId)
        else:
          if state.searchMode != ModeAUR:
            state.visibleIndices.setLen(0)
            if state.searchMode == ModeAUR:
              state.statusMessage = "Type to search AUR..."
  of MsgSearchResults:
    handleSearchResults(state, msg, listHeight)
  of MsgDetailsLoaded:
    if state.detailsCache.len >= DetailsCacheLimit:
      state.detailsCache.clear()
    state.detailsCache[msg.pkgIdx] = msg.content
  of MsgError:
    state.searchBuffer = "Error: " & msg.errMsg
    state.isSearching = false
    state.statusMessage = "Error"
