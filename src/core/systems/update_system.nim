import std/[monotimes, tables, times]
import ../types
import input_system

proc detailsCacheBytes(cache: Table[int32, string]): int =
  for content in cache.values:
    result += content.len

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
    if state.detailsCache.len >= DetailsCacheLimit or
        detailsCacheBytes(state.detailsCache) + msg.content.len > DetailsCacheByteBudget:
      state.detailsCache.clear()
    state.detailsCache[msg.pkgIdx] = msg.content
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
