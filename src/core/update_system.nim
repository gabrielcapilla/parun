import std/[monotimes, times]
import types, state
import input_system

proc clampDetailContent(content: string): string =
  if content.len <= MaxDetailPayloadBytes:
    return content
  const Suffix = "\n\n[truncated]"
  let keep = max(0, MaxDetailPayloadBytes - Suffix.len)
  result = content[0 ..< keep]
  result.add(Suffix)

proc update*(state: var AppState, msg: var Msg, listHeight: int) =
  state.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(state, msg.key, listHeight)
  of MsgTick:
    if state.debouncePending:
      if (getMonoTime() - state.lastInputTime).inMilliseconds() > 500:
        state.debouncePending = false
        state.statusMessage = ""
  of MsgSearchResults:
    discard
  of MsgDetailsLoaded:
    if msg.pkgSlot != state.activeSlot:
      state.needsRedraw = false
      return
    let content = clampDetailContent(msg.content)
    if detailCacheLen(state.detailsCache) >= DetailsCacheLimit or
        detailCacheUsedBytes(state.detailsCache) + content.len > DetailsCacheByteBudget:
      clearDetailCache(state.detailsCache)
      state.wrappedDetails = @[]
      state.lastDetailIdx = -1
    detailCachePut(state.detailsCache, msg.pkgIdx, content)
    if msg.pkgIdx == state.pendingDetailIdx and msg.pkgSlot == state.pendingDetailSlot:
      state.pendingDetailIdx = -1
      state.detailRequestInFlight = false
  of MsgWorkerDiagnostics:
    discard
  of MsgError:
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.searchBuffer = "Error: " & msg.errMsg
    state.isSearching = false
    state.statusMessage = "Error"
