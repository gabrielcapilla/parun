import std/[strutils, sets, tables, algorithm, math]
import types
import simd

template getName*(state: AppState, p: CompactPackage): string =
  state.stringPool[int(p.nameOffset) ..< int(p.nameOffset) + int(p.nameLen)]

template getVersion*(state: AppState, p: CompactPackage): string =
  state.stringPool[int(p.verOffset) ..< int(p.verOffset) + int(p.verLen)]

template getRepo*(state: AppState, p: CompactPackage): string =
  state.repoList[int(p.repoIdx)]

func getPkgId*(state: AppState, idx: int32): string =
  let p = state.pkgs[int(idx)]
  state.getRepo(p) & "/" & state.getName(p)

func getEffectiveQuery*(buffer: string): string =
  if buffer.startsWith("aur/"):
    return buffer[4 ..^ 1]
  return buffer

func filterIndices(state: AppState, query: string): seq[int32] =
  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()

  if cleanQuery.len == 0:
    result = newSeq[int32](state.pkgs.len)
    for i in 0 ..< state.pkgs.len:
      result[i] = int32(i)
    return

  let tokens = cleanQuery.splitWhitespace()
  if tokens.len == 0:
    return @[]

  var scored = newSeqOfCap[tuple[idx: int32, score: int]](state.pkgs.len div 4)

  for i in 0 ..< state.pkgs.len:
    let p = state.pkgs[i]
    var totalScore = 0
    var allTokensMatch = true

    for token in tokens:
      let s = scorePackageSimd(state.stringPool, p.nameOffset, p.nameLen, token)
      if s == 0:
        allTokensMatch = false
        break
      totalScore += s

    if allTokensMatch:
      scored.add((int32(i), totalScore))

  scored.sort do(a, b: auto) -> int:
    cmp(b.score, a.score)

  result = newSeqOfCap[int32](scored.len)
  for item in scored:
    result.add(item.idx)

func filterBySelection(state: AppState): seq[int32] =
  result = newSeqOfCap[int32](state.selected.len)
  if state.selected.len == 0:
    return

  for i in 0 ..< state.pkgs.len:
    let id = state.getPkgId(int32(i))
    if id in state.selected:
      result.add(int32(i))

func newState*(initialMode: SearchMode, initialShowDetails: bool): AppState =
  AppState(
    pkgs: @[],
    visibleIndices: @[],
    stringPool: newStringOfCap(4 * 1024 * 1024),
    repoList: @[],
    localPkgCount: 0,
    localPoolLen: 0,
    localRepoCount: 0,
    selected: initHashSet[string](),
    detailsCache: initTable[string, string](),
    cursor: 0,
    scroll: 0,
    searchBuffer: "",
    searchMode: initialMode,
    isSearching: false,
    showDetails: initialShowDetails,
    detailScroll: 0,
    viewingSelection: false,
  )

func update*(state: AppState, msg: Msg, listHeight: int): AppState =
  result = state
  result.needsRedraw = true

  case msg.kind
  of MsgInput:
    let k = msg.key

    if k == KeyUp:
      if result.visibleIndices.len > 0:
        result.cursor = min(result.visibleIndices.len - 1, result.cursor + 1)
        result.detailScroll = 0
    elif k == KeyDown:
      if result.visibleIndices.len > 0:
        result.cursor = max(0, result.cursor - 1)
        result.detailScroll = 0
    elif k == KeyLeft:
      if result.searchCursor > 0:
        result.searchCursor.dec()
    elif k == KeyRight:
      if result.searchCursor < result.searchBuffer.len:
        result.searchCursor.inc()
    elif k == KeyPageUp:
      if result.visibleIndices.len > 0:
        result.cursor = min(result.visibleIndices.len - 1, result.cursor + listHeight)
        result.detailScroll = 0
    elif k == KeyPageDown:
      if result.visibleIndices.len > 0:
        result.cursor = max(0, result.cursor - listHeight)
        result.detailScroll = 0
    elif k == KeyHome:
      if result.visibleIndices.len > 0:
        result.cursor = result.visibleIndices.len - 1
        result.scroll = max(0, result.cursor - listHeight + 1)
        result.detailScroll = 0
    elif k == KeyEnd:
      if result.visibleIndices.len > 0:
        result.cursor = 0
        result.scroll = 0
        result.detailScroll = 0
    elif k == KeyDetailUp:
      result.detailScroll = max(0, result.detailScroll - 1)
    elif k == KeyDetailDown:
      if result.visibleIndices.len > 0:
        let id = result.getPkgId(result.visibleIndices[result.cursor])
        if result.detailsCache.hasKey(id):
          let lines = result.detailsCache[id].countLines()
          if result.detailScroll < lines - 1:
            result.detailScroll.inc()
    elif k == KeyEnter:
      result.shouldInstall = true
    elif k == KeyCtrlA:
      if result.searchMode == ModeLocal:
        result.searchMode = ModeHybrid
      else:
        result.searchMode = ModeLocal
        if result.localPkgCount > 0:
          result.pkgs.setLen(result.localPkgCount)
          result.stringPool.setLen(result.localPoolLen)
          result.repoList.setLen(result.localRepoCount)
          result.visibleIndices = filterIndices(result, result.searchBuffer)
          result.cursor = 0
    elif k == KeyCtrlS:
      result.viewingSelection = not result.viewingSelection
      result.cursor = 0
      result.scroll = 0
      if result.viewingSelection:
        result.visibleIndices = filterBySelection(result)
      else:
        result.visibleIndices = filterIndices(result, result.searchBuffer)
    elif k == KeyEsc:
      if result.viewingSelection:
        result.viewingSelection = false
        result.visibleIndices = filterIndices(result, result.searchBuffer)
        result.cursor = 0
      elif result.searchBuffer.len > 0:
        result.searchBuffer = ""
        result.searchCursor = 0
        result.searchMode = ModeLocal
        if result.localPkgCount > 0:
          result.pkgs.setLen(result.localPkgCount)
          result.stringPool.setLen(result.localPoolLen)
          result.repoList.setLen(result.localRepoCount)
        result.visibleIndices = filterIndices(result, "")
        result.cursor = 0
        result.scroll = 0
      else:
        result.shouldQuit = true
    elif k == KeyTab:
      if result.visibleIndices.len > 0:
        let id = result.getPkgId(result.visibleIndices[result.cursor])
        if id in result.selected:
          result.selected.excl(id)
        else:
          result.selected.incl(id)
        if result.cursor < result.visibleIndices.len - 1:
          result.cursor.inc()
    elif k == KeyBack or k == KeyBackspace:
      if result.viewingSelection:
        result.viewingSelection = false

      if result.searchCursor > 0:
        result.searchBuffer.delete(result.searchCursor - 1 .. result.searchCursor - 1)
        result.searchCursor.dec()
        result.visibleIndices = filterIndices(result, result.searchBuffer)
        result.cursor = 0
        if result.searchBuffer.len == 0:
          result.searchMode = ModeLocal
    elif k.ord >= 32 and k.ord <= 126:
      if result.viewingSelection:
        result.viewingSelection = false

      result.searchBuffer.insert($k, result.searchCursor)
      result.searchCursor.inc()
      result.visibleIndices = filterIndices(result, result.searchBuffer)
      result.cursor = 0
    elif k == KeyF1:
      result.showDetails = not result.showDetails
    elif k == KeyCtrlR:
      result.shouldUninstall = true

    if result.visibleIndices.len > 0:
      result.cursor = clamp(result.cursor, 0, result.visibleIndices.len - 1)
      if result.cursor < result.scroll:
        result.scroll = result.cursor
      elif result.cursor >= result.scroll + listHeight:
        result.scroll = result.cursor - listHeight + 1
    else:
      result.scroll = 0
  of MsgSearchResults:
    if msg.isAppend:
      if msg.searchId > 0 and msg.searchId != result.searchId:
        return result

      if msg.searchId > 0:
        if result.localPkgCount > 0:
          result.pkgs.setLen(result.localPkgCount)
          result.stringPool.setLen(result.localPoolLen)
          result.repoList.setLen(result.localRepoCount)
        else:
          result.pkgs = @[]
          result.stringPool = ""
          result.repoList = @[]

      var remoteRepoMap = newSeq[uint8](msg.repos.len)
      for i, r in msg.repos:
        var found = -1
        for j, existing in result.repoList:
          if existing == r:
            found = j
            break
        if found == -1:
          remoteRepoMap[i] = uint8(result.repoList.len)
          result.repoList.add(r)
        else:
          remoteRepoMap[i] = uint8(found)

      let baseOffset = int32(result.stringPool.len)
      result.stringPool.add(msg.poolData)

      for p in msg.packedPkgs:
        var newP = p
        newP.repoIdx = remoteRepoMap[p.repoIdx]
        newP.nameOffset += baseOffset
        newP.verOffset += baseOffset
        result.pkgs.add(newP)

      if msg.searchId == 0:
        result.localPkgCount = result.pkgs.len
        result.localPoolLen = result.stringPool.len
        result.localRepoCount = result.repoList.len

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
      result.pkgs = msg.packedPkgs
      result.stringPool = msg.poolData
      result.repoList = msg.repos
      result.localPkgCount = result.pkgs.len
      result.localPoolLen = result.stringPool.len
      result.localRepoCount = result.repoList.len

      if not result.viewingSelection:
        result.visibleIndices = filterIndices(result, result.searchBuffer)
      result.cursor = 0
      result.scroll = 0

    result.isSearching = false
    result.justReceivedSearchResults = true
  of MsgDetailsLoaded:
    result.detailsCache[msg.pkgId] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
  of MsgTick:
    discard
