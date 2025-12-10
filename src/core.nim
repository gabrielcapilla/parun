import std/[strutils, sets, tables, algorithm, math, editdistance]
import types

template getName*(state: AppState, p: CompactPackage): string =
  state.stringPool[int(p.nameOffset) ..< int(p.nameOffset) + int(p.nameLen)]

template getVersion*(state: AppState, p: CompactPackage): string =
  state.stringPool[int(p.verOffset) ..< int(p.verOffset) + int(p.verLen)]

template getRepo*(state: AppState, p: CompactPackage): string =
  state.repoList[int(p.repoIdx)]

func getPkgId*(state: AppState, idx: int32): string =
  let p = state.pkgs[int(idx)]
  state.getRepo(p) & "/" & state.getName(p)

func scorePkg(pool: string, p: CompactPackage, query: string): int =
  let nameStart = int(p.nameOffset)
  let nameLen = int(p.nameLen)
  let packageName = pool[nameStart ..< nameStart + nameLen].toLowerAscii()

  if nameLen == query.len:
    var match = true
    for i in 0 ..< query.len:
      if packageName[i] != query[i]:
        match = false
        break
    if match:
      return 1000

  if nameLen >= query.len:
    var match = true
    for i in 0 ..< query.len:
      if packageName[i] != query[i]:
        match = false
        break
    if match:
      return 500

  var qIdx = 0
  for i in 0 ..< nameLen:
    if packageName[i] == query[qIdx]:
      inc qIdx
      if qIdx == query.len:
        return 250
    elif qIdx > 0:
      if packageName[i] == query[0]:
        qIdx = 1
      else:
        qIdx = 0

  let editDist = editDistance(packageName, query)
  let maxLength = max(packageName.len, query.len)
  if maxLength > 0:
    let similarity = 1.0 - (float(editDist) / float(maxLength))

    if similarity >= 0.6:
      return int(similarity * 200)

  return 0

func filterIndices(state: AppState, query: string): seq[int32] =
  let cleanQuery = query.strip()
  if cleanQuery.len == 0:
    result = newSeq[int32](state.pkgs.len)
    for i in 0 ..< state.pkgs.len:
      result[i] = int32(i)
    return

  let qLow = cleanQuery.toLowerAscii()
  var scored = newSeqOfCap[tuple[idx: int32, score: int]](1000)

  for i in 0 ..< state.pkgs.len:
    let s = scorePkg(state.stringPool, state.pkgs[i], qLow)
    if s > 0:
      scored.add((int32(i), s))

  scored.sort do(a, b: auto) -> int:
    cmp(b.score, a.score)

  result = newSeqOfCap[int32](scored.len)
  for item in scored:
    result.add(item.idx)

func newState*(): AppState =
  AppState(
    pkgs: @[],
    visibleIndices: @[],
    stringPool: newStringOfCap(1024 * 1024),
    repoList: @[],
    localPkgCount: 0,
    localPoolLen: 0,
    localRepoCount: 0,
    selected: initHashSet[string](),
    detailsCache: initTable[string, string](),
    cursor: 0,
    scroll: 0,
    searchBuffer: "",
    isSearching: false,
    showDetails: true,
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
    elif k == KeyDown:
      if result.visibleIndices.len > 0:
        result.cursor = max(0, result.cursor - 1)
    elif k == KeyEnter:
      result.shouldInstall = true
    elif k == KeyEsc:
      if result.searchBuffer.len > 0:
        result.searchBuffer = ""
        result.searchCursor = 0

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
      if result.searchCursor > 0:
        result.searchBuffer.delete(result.searchCursor - 1 .. result.searchCursor - 1)
        result.searchCursor.dec()

        result.visibleIndices = filterIndices(result, result.searchBuffer)
        result.cursor = 0
    elif k.ord >= 32 and k.ord <= 126:
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

      result.visibleIndices = filterIndices(result, result.searchBuffer)
    else:
      result.pkgs = msg.packedPkgs
      result.stringPool = msg.poolData
      result.repoList = msg.repos

      result.localPkgCount = result.pkgs.len
      result.localPoolLen = result.stringPool.len
      result.localRepoCount = result.repoList.len

      result.visibleIndices = filterIndices(result, result.searchBuffer)

    result.isSearching = false
    result.justReceivedSearchResults = true

    result.cursor = 0
    result.scroll = 0
  of MsgDetailsLoaded:
    result.detailsCache[msg.pkgId] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
  of MsgTick:
    discard
