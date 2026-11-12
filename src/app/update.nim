import std/[monotimes, times]
import ../catalog/[model, state]
import input

func detailRevealDurationMs(waitMs: int, speed: DetailAnimationSpeed): int =
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
  state.needsRedraw = true

  case msg.kind
  of MsgInput:
    processInput(state, msg.key, listHeight)
  of MsgTick:
    if state.debouncePending:
      if (getMonoTime() - state.lastInputTime).inMilliseconds() > 500:
        state.debouncePending = false
        state.statusMessage = ""
  of MsgDetailsLoaded:
    if msg.detailGeneration != 0 and msg.detailGeneration != state.detailGeneration:
      state.needsRedraw = false
      return
    if msg.pkgSlot != state.activeSlot:
      state.needsRedraw = false
      return
    if msg.quality == DetailFallback and detailCacheHas(state.detailsCache, msg.pkgIdx):
      if msg.pkgIdx == state.pendingDetailIdx and msg.pkgSlot == state.pendingDetailSlot:
        state.pendingDetailIdx = -1
        state.detailRequestInFlight = false
      if msg.pkgIdx == state.detailEnrichmentIdx and
          msg.pkgSlot == state.detailEnrichmentSlot:
        state.detailEnrichmentInFlight = false
        state.detailEnrichmentIdx = -1
      return
    let content = limitDetailPayload(msg.content)
    if detailCacheLen(state.detailsCache) >= DetailsCacheLimit or
        detailCacheUsedBytes(state.detailsCache) + content.len > DetailsCacheByteBudget:
      clearDetailCache(state.detailsCache)
      state.wrappedDetails = @[]
      state.lastDetailIdx = -1
    detailCachePut(state.detailsCache, msg.pkgIdx, content)
    if msg.pkgIdx == state.lastDetailIdx:
      state.wrappedDetails = @[]
      state.lastDetailIdx = -1
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
    if msg.pkgIdx == state.detailEnrichmentIdx and
        msg.pkgSlot == state.detailEnrichmentSlot:
      state.detailEnrichmentInFlight = false
      state.detailEnrichmentIdx = -1
  of MsgWorkerDiagnostics:
    discard
  of MsgError:
    if msg.errorDetailGeneration != 0 and
        msg.errorDetailGeneration != state.detailGeneration:
      state.needsRedraw = false
      return
    if msg.errorDetailGeneration != 0 and msg.errorDetailSlot != state.activeSlot:
      state.needsRedraw = false
      return
    if msg.errorDetailGeneration != 0:
      if msg.errorDetailIdx == state.pendingDetailIdx:
        state.pendingDetailIdx = -1
        state.detailRequestInFlight = false
      if msg.errorDetailIdx == state.detailEnrichmentIdx:
        state.detailEnrichmentInFlight = false
        state.detailEnrichmentIdx = -1
      state.statusMessage = msg.errMsg
      return
    state.pendingDetailIdx = -1
    state.detailRequestInFlight = false
    state.detailEnrichmentInFlight = false
    state.detailEnrichmentIdx = -1
    state.searchBuffer = "Error: " & msg.errMsg
    state.statusMessage = "Error"
