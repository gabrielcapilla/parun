## Message reducer for application state.
##
## Notes:
## - This is the central state transition point for UI/events.
## - Input, timer ticks, detail payloads, and errors converge here.
## - Expensive work is delegated to worker/input systems; reducer keeps control flow explicit.
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

func detailRevealDurationMs(waitMs: int, speed: DetailAnimationSpeed): int =
  ## Keeps reveal time tied to fetch latency, then scales user preference.
  let base = min(420, max(80, waitMs div 2))
  case speed
  of DetailAnimationFast:
    base
  of DetailAnimationNormal:
    min(700, max(140, (base * 3) div 2))
  of DetailAnimationSlow:
    min(1100, max(240, base * 2))
  of DetailAnimationUltraSlow:
    min(2600, max(600, base * 2))

proc update*(state: var AppState, msg: var Msg, listHeight: int) =
  ## Applies one message to `state` and updates redraw intent.
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
    if state.detailsAnimationEnabled and msg.pkgIdx == state.pendingDetailIdx and
        msg.pkgSlot == state.pendingDetailSlot:
      let waitMs = int((getMonoTime() - state.detailTargetSince).inMilliseconds())
      let revealMs = detailRevealDurationMs(waitMs, state.detailAnimationSpeed)
      state.detailScramble = DetailScramble(
        pkgIdx: msg.pkgIdx,
        pkgSlot: msg.pkgSlot,
        startedAt: getMonoTime(),
        durationMs: revealMs,
        active: true,
      )
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
