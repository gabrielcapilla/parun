import std/[strutils, sets, tables, algorithm, math]
import types, simd, pkgManager

const MaxDetailsCache = 50

template getName*(state: AppState, p: CompactPackage): string =
  let page = state.memoryPages[p.pageIdx]
  page[p.pageOffset ..< p.pageOffset + p.nameLen]

template getVersion*(state: AppState, p: CompactPackage): string =
  let page = state.memoryPages[p.pageIdx]
  let start = p.pageOffset + p.nameLen + 1
  var curr = start
  while curr < page.len.uint16 and page[curr] != '\0':
    inc(curr)
  page[start ..< curr]

template getRepo*(state: AppState, p: CompactPackage): string =
  state.repoList[p.repoIdx]

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

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return @[]

  var scored = newSeqOfCap[tuple[idx: int32, score: int]](min(2000, state.pkgs.len))

  for i in 0 ..< state.pkgs.len:
    let p = state.pkgs[i]

    let s = scorePackageSimd(state.memoryPages[p.pageIdx], p.pageOffset, p.nameLen, ctx)
    if s > 0:
      scored.add((int32(i), s))

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
    pkgs: newSeqOfCap[CompactPackage](20000),
    memoryPages: newSeq[string](),
    repoList: @[],
    visibleIndices: @[],
    localPkgCount: 0,
    localPageCount: 0,
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
    searchId: 1,
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
              result.memoryPages.setLen(result.localPageCount)
              result.repoList.setLen(result.localRepoCount)
              result.visibleIndices = filterIndices(result, result.searchBuffer)
              result.cursor = 0
        return

      if k == KeyCtrlN:
        result.searchId.inc()
        result.pkgs = newSeqOfCap[CompactPackage](0)
        result.memoryPages = newSeq[string]()
        result.repoList = newSeq[string]()

        result.visibleIndices = @[]
        result.selected = initHashSet[string]()
        result.cursor = 0
        result.scroll = 0
        result.detailsCache = initTable[string, string]()
        result.localPkgCount = 0

        if result.dataSource == SourceSystem:
          result.dataSource = SourceNimble
          requestLoadNimble(result.searchId)
        else:
          result.dataSource = SourceSystem
          result.searchMode = ModeLocal
          requestLoadAll(result.searchId)
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
    if msg.searchId != result.searchId:
      return result

    if msg.isAppend:
      var remoteRepoMap = newSeq[uint16](msg.repos.len)
      for i, r in msg.repos:
        var found = -1
        for j, existing in result.repoList:
          if existing == r:
            found = j
            break
        if found == -1:
          remoteRepoMap[i] = uint16(result.repoList.len)
          result.repoList.add(r)
        else:
          remoteRepoMap[i] = uint16(found)

      let basePageIdx = uint16(result.memoryPages.len)
      for page in msg.pages:
        result.memoryPages.add(page)

      for p in msg.packedPkgs:
        var newP = p
        newP.repoIdx = remoteRepoMap[p.repoIdx]
        newP.pageIdx += basePageIdx
        result.pkgs.add(newP)

      if result.searchBuffer.len == 0 or result.dataSource == SourceNimble:
        result.localPkgCount = result.pkgs.len
        result.localPageCount = result.memoryPages.len
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
      result.memoryPages = msg.pages
      result.repoList = msg.repos
      result.localPkgCount = result.pkgs.len
      result.localPageCount = result.memoryPages.len
      result.localRepoCount = result.repoList.len

      if not result.viewingSelection:
        result.visibleIndices = filterIndices(result, result.searchBuffer)
      result.cursor = 0
      result.scroll = 0

    result.isSearching = false
    result.justReceivedSearchResults = true
  of MsgDetailsLoaded:
    if result.detailsCache.len >= MaxDetailsCache:
      result.detailsCache.clear()
    result.detailsCache[msg.pkgId] = msg.content
  of MsgError:
    result.searchBuffer = "Error: " & msg.errMsg
    result.isSearching = false
  of MsgTick:
    discard
