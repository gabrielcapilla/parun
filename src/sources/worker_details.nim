import std/[monotimes, os, tables, times]
import ../catalog/model
import worker_protocol, worker_cache, worker_exec
import nimble, nimble_detail_cache
import pacman_query
import pacman_sync

const NimbleManifestTimeoutMs = 10_000

proc sendDetailsLoaded(
    resChan: var Channel[Msg],
    req: WorkerReq,
    content: string,
    quality: DetailQuality = DetailManifest,
) {.inline.} =
  resChan.send(
    Msg(
      kind: MsgDetailsLoaded,
      pkgIdx: req.pkgIdx,
      pkgSlot: req.pkgSlot,
      detailGeneration: req.detailGeneration,
      quality: quality,
      content: content,
    )
  )

proc sendDetailError(
    resChan: var Channel[Msg], req: WorkerReq, message: string
) {.inline.} =
  resChan.send(
    Msg(
      kind: MsgError,
      errMsg: message,
      errorDetailIdx: req.pkgIdx,
      errorDetailSlot: req.pkgSlot,
      errorDetailGeneration: req.detailGeneration,
    )
  )

proc buildDetailCacheKey(req: WorkerReq): string {.inline.} =
  let versionLen =
    if req.source == SourceNimble:
      NimbleDetailFormatVersion.len + 1
    else:
      0
  result =
    newStringOfCap(req.pkgRepo.len + req.pkgName.len + req.pkgUrl.len + versionLen + 17)
  if req.source == SourceNimble:
    result.add(NimbleDetailFormatVersion)
    result.add(':')
  result.add($req.pkgSlot)
  result.add(':')
  result.add(req.pkgRepo)
  result.add(':')
  result.add(req.pkgName)
  result.add(':')
  result.add(req.pkgUrl)

proc tryFetchNimbleDetail(
    req: WorkerReq,
    metaUrl, metaTagsLine: string,
    rawBranchCache: var Table[string, string],
    content: var string,
): bool =
  let cacheKey = cacheKeyForRepo(metaUrl)
  let knownBranch =
    if cacheKey.len > 0 and rawBranchCache.hasKey(cacheKey):
      rawBranchCache[cacheKey]
    else:
      ""
  let candidates = orderCandidatesByBranch(
    getRawNimbleFileCandidatesWithBranch(metaUrl, req.pkgName), knownBranch
  )
  let started = getMonoTime()
  for (branch, candidateUrl) in candidates:
    let elapsedMs = int((getMonoTime() - started).inMilliseconds())
    let remainingMs = NimbleManifestTimeoutMs - elapsedMs
    if remainingMs <= 0:
      break
    try:
      content = parseNimbleInfo(
        downloadWithRetry(
          candidateUrl,
          maxRetries = 2,
          timeoutMs = remainingMs,
          maxOutputBytes = MaxDetailPayloadBytes * 4,
        ),
        req.pkgName,
        metaUrl,
        metaTagsLine,
      )
      if cacheKey.len > 0 and branch.len > 0:
        rawBranchCache[cacheKey] = branch
      return true
    except CatchableError:
      discard
  false

proc processDetailRequests*(
    firstReq: WorkerReq,
    reqChan: var Channel[WorkerReq],
    resChan: var Channel[Msg],
    currentReq: var WorkerReq,
    hasReq: var bool,
    detailBatch: var seq[WorkerReq],
    detailsCache: var PackedDetailCache,
    rawBranchCache: var Table[string, string],
    toolDef: ToolDef,
    localRevdeps: ReverseDepIndex,
) =
  detailBatch.setLen(0)
  detailBatch.add(firstReq)

  while true:
    let (ok, nextReq) = reqChan.tryRecv()
    if not ok:
      break
    if nextReq.kind == ReqDetails:
      detailBatch[0] = nextReq
    else:
      currentReq = nextReq
      hasReq = true
      break

  for req in detailBatch:
    let cacheKey = buildDetailCacheKey(req)
    var cachedDetail = ""
    if getDetailsCache(detailsCache, cacheKey, cachedDetail):
      sendDetailsLoaded(resChan, req, cachedDetail)
      continue

    if req.source == SourceNimble:
      let metaUrl = req.pkgUrl
      let metaTagsLine = ""
      if metaUrl.len > 0:
        var cachedManifest = ""
        if loadNimbleDetail(req.pkgName, metaUrl, cachedManifest):
          let content = clampDetailPayload(cachedManifest)
          putDetailsCache(detailsCache, cacheKey, content)
          sendDetailsLoaded(resChan, req, content)
          continue

        var nimbleContent = ""
        if tryFetchNimbleDetail(
          req, metaUrl, metaTagsLine, rawBranchCache, nimbleContent
        ):
          let content = clampDetailPayload(nimbleContent)
          discard writeNimbleDetail(req.pkgName, metaUrl, content)
          putDetailsCache(detailsCache, cacheKey, content)
          sendDetailsLoaded(resChan, req, content)
          continue

      let (fallbackRaw, _) = execWithErrorCheck(
        "nimble", ["search", req.pkgName], emLenient, MaxDetailPayloadBytes * 4
      )
      let info = clampDetailPayload(formatFallbackInfo(fallbackRaw))
      if info.len > 0:
        sendDetailsLoaded(resChan, req, info, DetailFallback)
      else:
        sendDetailError(
          resChan,
          req,
          "Nimble detail enrichment failed and produced no fallback for " & req.pkgName,
        )
      continue

    let target =
      if req.pkgRepo == "local":
        req.pkgName
      else:
        req.pkgRepo & "/" & req.pkgName

    if req.pkgRepo != "local" and toolDef.bin == "pacman":
      let syncText = readSyncDesc(req.pkgRepo, req.pkgName)
      if syncText.len > 0:
        let syncContent = clampDetailPayload(formatSyncDetails(req.pkgRepo, syncText))
        if syncContent.len > 0:
          putDetailsCache(detailsCache, cacheKey, syncContent)
          sendDetailsLoaded(resChan, req, syncContent)
          continue

    if req.pkgRepo == "local":
      let nativeDir = tables.getOrDefault(localRevdeps.dirByName, req.pkgName, "")
      if nativeDir.len > 0:
        let nativeContent =
          clampDetailPayload(formatLocalDetails(nativeDir, localRevdeps))
        if nativeContent.len > 0:
          putDetailsCache(detailsCache, cacheKey, nativeContent)
          sendDetailsLoaded(resChan, req, nativeContent)
          continue
      if dirExists(LocalDbPath):
        sendDetailError(resChan, req, "Failed to get package info for " & req.pkgName)
        continue
    let bin = if req.pkgRepo == "local": "pacman" else: toolDef.bin
    var cmd = newStringOfCap(bin.len + target.len + 8)
    cmd.add(bin)
    if req.pkgRepo == "local":
      cmd.add(" -Qi ")
    else:
      cmd.add(" -Si ")
    cmd.add(target)

    let (rawContent, ok) = execWithErrorCheck(
      bin,
      [(if req.pkgRepo == "local": "-Qi" else: "-Si"), target],
      emStrict,
      MaxDetailPayloadBytes * 4,
    )
    if not ok:
      sendDetailError(resChan, req, "Failed to get package info for " & req.pkgName)
      continue

    let content = clampDetailPayload(rawContent)
    putDetailsCache(detailsCache, cacheKey, content)
    sendDetailsLoaded(resChan, req, content)
