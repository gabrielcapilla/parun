import std/[strutils, sets, tables, algorithm, math]
import types, simd, pkgManager

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

func newState*(
    initialMode: SearchMode, initialShowDetails: bool, useVim: bool, startNimble: bool
): AppState =
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
    commandBuffer: "",
    searchMode: initialMode,
    isSearching: false,
    showDetails: initialShowDetails,
    detailScroll: 0,
    viewingSelection: false,
    inputMode: if useVim: ModeVimNormal else: ModeStandard,
    dataSource: if startNimble: SourceNimble else: SourceSystem,
  )

func toggleSelection(state: var AppState) =
  if state.visibleIndices.len > 0:
    let id = state.getPkgId(state.visibleIndices[state.cursor])
    if id in state.selected:
      state.selected.excl(id)
    else:
      state.selected.incl(id)
    if state.cursor < state.visibleIndices.len - 1:
      state.cursor.inc()

func handleVimCommand(state: var AppState, k: char) =
  case k
  of KeyEnter:
    let cmd = state.commandBuffer.strip()
    if cmd == "q" or cmd == "q!":
      state.shouldQuit = true
    else:
      state.commandBuffer = ""
      state.inputMode = ModeVimNormal
  of KeyEsc:
    state.commandBuffer = ""
    state.inputMode = ModeVimNormal
  of KeyBack, KeyBackspace:
    if state.commandBuffer.len > 0:
      state.commandBuffer.setLen(state.commandBuffer.len - 1)
    else:
      state.inputMode = ModeVimNormal
  elif k.ord >= 32 and k.ord <= 126:
    state.commandBuffer.add(k)
  else:
    discard

func handleVimNormal(state: var AppState, k: char, listHeight: int) =
  case k
  of 'j', KeyDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - 1)
      state.detailScroll = 0
  of 'k', KeyUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + 1)
      state.detailScroll = 0
  of 'g', KeyHome:
    if state.visibleIndices.len > 0:
      state.cursor = state.visibleIndices.len - 1
      state.scroll = max(0, state.cursor - listHeight + 1)
      state.detailScroll = 0
  of 'G', KeyEnd:
    if state.visibleIndices.len > 0:
      state.cursor = 0
      state.scroll = 0
      state.detailScroll = 0
  of KeyCtrlU, KeyPageUp:
    if state.visibleIndices.len > 0:
      state.cursor = min(state.visibleIndices.len - 1, state.cursor + listHeight)
      state.detailScroll = 0
  of KeyCtrlD, KeyPageDown:
    if state.visibleIndices.len > 0:
      state.cursor = max(0, state.cursor - listHeight)
      state.detailScroll = 0
  of KeyCtrlY:
    state.detailScroll = max(0, state.detailScroll - 1)
  of KeyCtrlE:
    if state.visibleIndices.len > 0:
      let id = state.getPkgId(state.visibleIndices[state.cursor])
      if state.detailsCache.hasKey(id):
        let lines = state.detailsCache[id].countLines()
        if state.detailScroll < lines - 1:
          state.detailScroll.inc()
  of 'i':
    state.inputMode = ModeVimInsert
  of '/':
    state.searchBuffer = ""
    state.searchCursor = 0
    state.visibleIndices = filterIndices(state, "")
    state.inputMode = ModeVimInsert
  of ':':
    state.commandBuffer = ""
    state.inputMode = ModeVimCommand
  of KeySpace:
    toggleSelection(state)
  of 'x':
    state.shouldUninstall = true
  of KeyEnter:
    state.shouldInstall = true
  of KeyEsc:
    if state.searchBuffer.len > 0:
      state.searchBuffer = ""
      state.searchCursor = 0
      state.visibleIndices = filterIndices(state, "")
    elif state.viewingSelection:
      state.viewingSelection = false
      state.visibleIndices = filterIndices(state, "")
  else:
    discard

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
            if result.localPkgCount > 0:
              result.pkgs.setLen(result.localPkgCount)
              result.stringPool.setLen(result.localPoolLen)
              result.repoList.setLen(result.localRepoCount)
              result.visibleIndices = filterIndices(result, result.searchBuffer)
              result.cursor = 0
        return

      if k == KeyCtrlN:
        result.pkgs = @[]
        result.stringPool = ""
        result.repoList = @[]
        result.visibleIndices = @[]
        result.selected = initHashSet[string]()
        result.cursor = 0
        result.scroll = 0
        result.detailsCache = initTable[string, string]()
        result.localPkgCount = 0

        if result.dataSource == SourceSystem:
          result.dataSource = SourceNimble
          requestLoadNimble()
        else:
          result.dataSource = SourceSystem
          result.searchMode = ModeLocal
          requestLoadAll()
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

    if result.inputMode == ModeVimCommand:
      handleVimCommand(result, k)
    elif result.inputMode == ModeVimNormal:
      handleVimNormal(result, k, listHeight)
    else:
      if result.inputMode == ModeVimInsert and k == KeyEsc:
        result.inputMode = ModeVimNormal
        return

      if k == KeyUp:
        if result.visibleIndices.len > 0:
          result.cursor = min(result.visibleIndices.len - 1, result.cursor + 1)
          result.detailScroll = 0
      elif k == KeyDown:
        if result.visibleIndices.len > 0:
          result.cursor = max(0, result.cursor - 1)
          result.detailScroll = 0
      elif k == KeyPageUp:
        if result.visibleIndices.len > 0:
          result.cursor = min(result.visibleIndices.len - 1, result.cursor + listHeight)
      elif k == KeyPageDown:
        if result.visibleIndices.len > 0:
          result.cursor = max(0, result.cursor - listHeight)
      elif k == KeyBack or k == KeyBackspace:
        if result.viewingSelection:
          result.viewingSelection = false
        if result.searchCursor > 0:
          result.searchBuffer.delete(result.searchCursor - 1 .. result.searchCursor - 1)
          result.searchCursor.dec()
          result.visibleIndices = filterIndices(result, result.searchBuffer)
          result.cursor = 0
      elif k == KeyLeft:
        if result.searchCursor > 0:
          result.searchCursor.dec()
      elif k == KeyRight:
        if result.searchCursor < result.searchBuffer.len:
          result.searchCursor.inc()
      elif k.ord >= 32 and k.ord <= 126:
        if result.viewingSelection:
          result.viewingSelection = false
        result.searchBuffer.insert($k, result.searchCursor)
        result.searchCursor.inc()
        result.visibleIndices = filterIndices(result, result.searchBuffer)
        result.cursor = 0
      elif k == KeyTab:
        toggleSelection(result)
      elif k == KeyEnter:
        result.shouldInstall = true
      elif k == KeyCtrlR:
        result.shouldUninstall = true
      elif k == KeyEsc:
        if result.viewingSelection:
          result.viewingSelection = false
          result.visibleIndices = filterIndices(result, result.searchBuffer)
        elif result.searchBuffer.len > 0:
          result.searchBuffer = ""
          result.searchCursor = 0
          result.visibleIndices = filterIndices(result, "")
        else:
          result.shouldQuit = true

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
