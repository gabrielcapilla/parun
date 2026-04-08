import std/[httpclient, strutils]
import ../core/types
import worker_types, worker_cache, worker_exec
import nimble

proc sendDetailsLoaded(
    resChan: var Channel[Msg], req: WorkerReq, content: string
) {.inline.} =
  resChan.send(
    Msg(
      kind: MsgDetailsLoaded, pkgIdx: req.pkgIdx, pkgSlot: req.pkgSlot, content: content
    )
  )

proc buildDetailCacheKey(req: WorkerReq): string {.inline.} =
  result = newStringOfCap(req.pkgRepo.len + req.pkgName.len + 16)
  result.add($req.pkgSlot)
  result.add(':')
  result.add(req.pkgRepo)
  result.add(':')
  result.add(req.pkgName)

proc tryFetchNimbleDetail(
    req: WorkerReq,
    nimbleMetaCache: PackedNimbleMetaCache,
    client: HttpClient,
    content: var string,
): bool =
  var metaUrl = ""
  var metaTagsLine = ""
  if not getNimbleMeta(nimbleMetaCache, req.pkgName, metaUrl, metaTagsLine):
    return false

  let rawBase = getRawBaseUrl(metaUrl)
  if rawBase.len == 0:
    return false

  let lowerName = req.pkgName.toLowerAscii()
  for branch in ["master", "main"]:
    try:
      content = parseNimbleInfo(
        downloadWithRetry(
          client, rawBase & "/" & branch & "/" & req.pkgName & ".nimble", maxRetries = 2
        ),
        req.pkgName,
        metaUrl,
        metaTagsLine,
      )
      return true
    except CatchableError:
      if req.pkgName != lowerName:
        try:
          content = parseNimbleInfo(
            downloadWithRetry(
              client,
              rawBase & "/" & branch & "/" & lowerName & ".nimble",
              maxRetries = 2,
            ),
            req.pkgName,
            metaUrl,
            metaTagsLine,
          )
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
    nimbleMetaCache: PackedNimbleMetaCache,
    toolDef: ToolDef,
    client: HttpClient,
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
      var nimbleContent = ""
      if tryFetchNimbleDetail(req, nimbleMetaCache, client, nimbleContent):
        let content = clampDetailPayload(nimbleContent)
        putDetailsCache(detailsCache, cacheKey, content)
        sendDetailsLoaded(resChan, req, content)
        continue

      let (fallbackRaw, _) =
        execWithErrorCheck("nimble search " & req.pkgName, emLenient)
      let info = clampDetailPayload(formatFallbackInfo(fallbackRaw))
      putDetailsCache(detailsCache, cacheKey, info)
      sendDetailsLoaded(resChan, req, info)
      continue

    let target =
      if req.pkgRepo == "local":
        req.pkgName
      else:
        req.pkgRepo & "/" & req.pkgName
    let bin = if req.pkgRepo == "local": "pacman" else: toolDef.bin
    var cmd = newStringOfCap(bin.len + target.len + 8)
    cmd.add(bin)
    if req.pkgRepo == "local":
      cmd.add(" -Qi ")
    else:
      cmd.add(" -Si ")
    cmd.add(target)

    let (rawContent, ok) = execWithErrorCheck(cmd, emStrict)
    if not ok:
      resChan.send(
        Msg(kind: MsgError, errMsg: "Failed to get package info for " & req.pkgName)
      )
      continue

    let content = clampDetailPayload(rawContent)
    putDetailsCache(detailsCache, cacheKey, content)
    sendDetailsLoaded(resChan, req, content)
