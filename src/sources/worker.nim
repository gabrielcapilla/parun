import std/tables
import ../catalog/model
import ../diagnostics/memory_accounting
import worker_protocol
import source_contracts
import pacman_query
import worker_cache
import worker_details

proc buildWorkerMemoryReport(
    detailsCache: PackedDetailCache,
    detailBatch: seq[WorkerReq],
    localRevdeps: ReverseDepIndex,
): WorkerMemoryReport =
  var cacheSection = MemorySection(name: "worker_caches")
  cacheSection.addMetric(
    "details_cache",
    detailsCacheBytes(detailsCache),
    detailsCache.count,
    WorkerDetailsCacheLimit,
    "Worker-side detail text cache (packed metadata + arena)",
  )
  cacheSection.addSeqMetric(
    "detail_batch", detailBatch, "Pending detail requests coalesced in worker"
  )
  cacheSection.addTableMetric(
    "revdep_required_by", localRevdeps.requiredBy,
    "Precomputed Required By edges (native -Qi support)",
  )
  cacheSection.addTableMetric(
    "revdep_optional_for", localRevdeps.optionalFor,
    "Precomputed Optional For edges (native -Qi support)",
  )
  result.sections = @[cacheSection]

proc workerLoop*(
    toolType: PkgManagerType, reqChan: var Channel[WorkerReq], resChan: var Channel[Msg]
) {.thread.} =
  var currentReq: WorkerReq
  var hasReq = false
  var detailsCache = initDetailsCache()
  let toolDef = getToolDef(toolType)
  if toolDef.source notin {SourceSystem, SourceNimble}:
    resChan.send(
      Msg(
        kind: MsgError,
        errMsg: "Invalid active plugin source for worker: " & toolDef.key,
      )
    )
    return
  enforceCapabilities(toolDef, {capDetails}, "worker loop")

  var detailBatch = newSeqOfCap[WorkerReq](16)
  var localRevdeps = ReverseDepIndex()
  var localRevdepsLoaded = false
  var rawBranchCache = initTable[string, string]()

  while true:
    if not hasReq:
      currentReq = reqChan.recv()
    else:
      hasReq = false

    let req = currentReq

    try:
      case req.kind
      of ReqStop:
        break
      of ReqDiagnostics:
        resChan.send(
          Msg(
            kind: MsgWorkerDiagnostics,
            workerReport:
              buildWorkerMemoryReport(detailsCache, detailBatch, localRevdeps),
          )
        )
      of ReqDetails:
        if req.pkgRepo == "local" and not localRevdepsLoaded:
          localRevdeps = buildReverseDepIndex(LocalDbPath)
          localRevdepsLoaded = true
        processDetailRequests(
          req, reqChan, resChan, currentReq, hasReq, detailBatch, detailsCache,
          rawBranchCache, toolDef, localRevdeps,
        )
    except Exception as e:
      if req.kind == ReqDetails:
        resChan.send(
          Msg(
            kind: MsgError,
            errMsg: e.msg,
            errorDetailIdx: req.pkgIdx,
            errorDetailSlot: req.pkgSlot,
            errorDetailGeneration: req.detailGeneration,
          )
        )
      else:
        resChan.send(Msg(kind: MsgError, errMsg: e.msg))
