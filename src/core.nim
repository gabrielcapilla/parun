import std/[sets, tables]
import types, state, input, pkgManager

proc update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    let k = msg.key
    if result.inputMode != ModeVimCommand:
      if k == KeyCtrlA:
        if result.dataSource == SourceSystem:
          if result.searchMode == ModeLocal:
            result.searchMode = ModeHybrid
          else:
            result.searchMode = ModeLocal
            if result.systemDB.isLoaded:
              result.pkgs = result.systemDB.pkgs
              result.textBlocks = result.systemDB.textBlocks
              result.repos = result.systemDB.repos
              result.visibleIndices = filterIndices(result, result.searchBuffer)
              result.cursor = 0
        return

      if k == KeyCtrlN:
        saveCurrentToDB(result)
        result.searchId.inc()
        result.visibleIndices = @[]
        result.selected = initHashSet[string]()
        result.cursor = 0
        result.scroll = 0
        result.detailsCache = initTable[string, string]()
        result.searchBuffer = ""
        result.searchCursor = 0

        if result.dataSource == SourceSystem:
          result.dataSource = SourceNimble
          loadFromDB(result, SourceNimble)
          if not result.nimbleDB.isLoaded:
            requestLoadNimble(result.searchId)
          else:
            result.visibleIndices = filterIndices(result, "")
        else:
          result.dataSource = SourceSystem
          result.searchMode = ModeLocal
          loadFromDB(result, SourceSystem)
          if not result.systemDB.isLoaded:
            requestLoadAll(result.searchId)
          else:
            result.visibleIndices = filterIndices(result, "")
        return

      if k == KeyCtrlS:
        result.viewingSelection = not result.viewingSelection
        result.cursor = 0
        result.scroll = 0
        if result.viewingSelection:
          result.visibleIndices = filterBySelection(result)
        else:
          result.visibleIndices = filterIndices(result, result.searchBuffer)
        return

      if k == KeyF1:
        result.showDetails = not result.showDetails
        return

    handleInput(result, k, listHeight)
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
