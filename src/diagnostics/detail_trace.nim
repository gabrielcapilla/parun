import std/[json, monotimes, os, times]
import ../catalog/[detail_cache, model, sources]
import ../index/[source_index_codec, source_index_core]
import ../platform/procfs_metrics

type DetailTrace* = object
  path: string
  startedAt: MonoTime
  firstFrameSeen: bool
  detailsFrameSeen: bool
  loadingFrameSeen: bool

proc initDetailTrace*(path: string): DetailTrace =
  DetailTrace(path: path, startedAt: getMonoTime())

proc detailTraceEnabled*(trace: DetailTrace): bool {.inline.} =
  trace.path.len > 0

proc wrappedDetailsBytes(state: AppState): tuple[used, capacity, slots: int] =
  result.slots = capacity(state.wrappedDetails)
  result.capacity = result.slots * sizeof(string)
  for line in state.wrappedDetails:
    result.used += line.len
    result.capacity += capacity(line)

proc decodeRingBytes(state: AppState): tuple[used, capacity, entries: int] =
  for view in state.sourceViews:
    for meta in [view.versionBlobMeta, view.repoBlobMeta, view.urlBlobMeta]:
      result.entries += meta.ring.len
      result.capacity += capacity(meta.ring) * sizeof(DecodedColdBlobBlock)
      for entry in meta.ring:
        result.used += capacity(entry.data)

proc selectedDetailIndex(state: AppState): int32 {.inline.} =
  if state.visibleCount() > 0:
    state.visibleIdxAt(state.cursor)
  else:
    -1

proc writeDetailTrace(
    trace: var DetailTrace,
    stage: string,
    state: AppState,
    renderBuffer: string,
    payloadBytes: int,
    detailIdx: int32,
): bool =
  if not trace.detailTraceEnabled():
    return false

  let wrapped = wrappedDetailsBytes(state)
  let decodeRings = decodeRingBytes(state)
  let decodeStats = snapshotColdDecodeStats()
  let sample = readProcfsSample(getCurrentProcessId().int)
  let cacheHit = detailIdx >= 0 and detailCacheHas(state.detailsCache, detailIdx)
  let payload = %*{
    "stage": stage,
    "elapsed_ms": int((getMonoTime() - trace.startedAt).inMilliseconds()),
    "pid": sample.pid,
    "vm_rss_kb": sample.vmRssKb,
    "rss_kb": sample.rssKb,
    "pss_kb": sample.pssKb,
    "private_dirty_kb": sample.privateDirtyKb,
    "rss_anon_kb": sample.rssAnonKb,
    "rss_file_kb": sample.rssFileKb,
    "detail_idx": detailIdx,
    "payload_bytes": payloadBytes,
    "detail_cache_hit": cacheHit,
    "detail_cache_len": detailCacheLen(state.detailsCache),
    "detail_cache_used_bytes": detailCacheUsedBytes(state.detailsCache),
    "detail_cache_capacity_bytes": detailCacheCapacityBytes(state.detailsCache),
    "wrapped_details_len": state.wrappedDetails.len,
    "wrapped_details_used_bytes": wrapped.used,
    "wrapped_details_capacity_bytes": wrapped.capacity,
    "wrapped_details_capacity_slots": wrapped.slots,
    "render_buffer_len": renderBuffer.len,
    "render_buffer_capacity": capacity(renderBuffer),
    "decode_ring_entries": decodeRings.entries,
    "decode_ring_used_bytes": decodeRings.used,
    "decode_ring_capacity_bytes": decodeRings.capacity,
    "cold_decode_requests": decodeStats.requests,
    "cold_decode_hits": decodeStats.hits,
    "cold_decode_misses": decodeStats.misses,
    "cold_decode_blocks": decodeStats.decodedBlocks,
    "cold_decode_bytes": decodeStats.decodedBytes,
    "last_detail_idx": state.lastDetailIdx,
    "last_detail_width": state.lastDetailWidth,
    "pending_detail_idx": state.pendingDetailIdx,
    "detail_request_in_flight": state.detailRequestInFlight,
    "detail_enrichment_in_flight": state.detailEnrichmentInFlight,
    "detail_enrichment_idx": state.detailEnrichmentIdx,
    "detail_scramble_active": state.detailScramble.active,
    "cold_detail_wraps": state.perf.coldDetailWraps,
    "cold_detail_lines": state.perf.coldDetailLines,
    "cold_detail_cache_hits": state.perf.coldDetailCacheHits,
    "cold_detail_cache_misses": state.perf.coldDetailCacheMisses,
    "cold_detail_requests": state.perf.coldDetailRequests,
  }

  let parent = parentDir(trace.path)
  if parent.len > 0:
    createDir(parent)
  let file = open(trace.path, fmAppend)
  defer:
    file.close()
  file.writeLine($payload)
  true

proc traceDetailEvent*(
    trace: var DetailTrace,
    stage: string,
    state: AppState,
    renderBuffer: string,
    payloadBytes: int = 0,
    detailIdx: int32 = -1,
) =
  discard trace.writeDetailTrace(stage, state, renderBuffer, payloadBytes, detailIdx)

proc traceDetailLoadingFrame*(
    trace: var DetailTrace, state: AppState, renderBuffer: string
) =
  if trace.detailTraceEnabled() and not trace.loadingFrameSeen:
    trace.loadingFrameSeen = true
    trace.traceDetailEvent(
      "detail-loading-frame",
      state,
      renderBuffer,
      detailIdx = selectedDetailIndex(state),
    )

proc traceDetailsFrame*(
    trace: var DetailTrace, state: AppState, renderBuffer: string, detailIdx: int32
) =
  if trace.detailTraceEnabled() and not trace.detailsFrameSeen:
    trace.detailsFrameSeen = true
    trace.traceDetailEvent("details-frame", state, renderBuffer, detailIdx = detailIdx)

proc traceDetailFirstFrame*(
    trace: var DetailTrace, state: AppState, renderBuffer: string
) =
  if trace.detailTraceEnabled() and not trace.firstFrameSeen:
    trace.firstFrameSeen = true
    trace.traceDetailEvent("first-frame", state, renderBuffer)

proc traceDetailWrappedRender*(
    trace: var DetailTrace, state: AppState, renderBuffer: string, detailIdx: int32
) =
  trace.traceDetailEvent(
    "first-wrapped-render", state, renderBuffer, detailIdx = detailIdx
  )

proc traceDetailRevealComplete*(
    trace: var DetailTrace, state: AppState, renderBuffer: string, detailIdx: int32
) =
  trace.traceDetailEvent("reveal-complete", state, renderBuffer, detailIdx = detailIdx)
