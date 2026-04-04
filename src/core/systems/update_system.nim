import std/[monotimes, tables, times]
import ../types
import input_system

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
    if state.detailsCache.len >= DetailsCacheLimit:
      state.detailsCache.clear()
    state.detailsCache[msg.pkgIdx] = msg.content
  of MsgWorkerDiagnostics:
    discard
  of MsgError:
    state.searchBuffer = "Error: " & msg.errMsg
    state.isSearching = false
    state.statusMessage = "Error"
