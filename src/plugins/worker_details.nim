## Worker-side details resolution pipeline.
##
## Notes:
## - Coalesces pending `ReqDetails` bursts to keep only the latest request.
## - Checks packed cache first, then resolves from source-specific backends.
## - Nimble requests prefer the repository URL carried in the mapped `.prix`
##   record; old indexes without that URL fall back to the Nimble metadata cache.
## - All outgoing payloads are clamped to UI budget before send.
import std/[httpclient, os]
import ../core/types
import worker_types, worker_cache, worker_exec, cache
import nimble

const NimbleDetailFormatVersion = "nimble-manifest-v4"

proc sendDetailsLoaded(
    resChan: var Channel[Msg], req: WorkerReq, content: string
) {.inline.} =
  resChan.send(
    Msg(
      kind: MsgDetailsLoaded, pkgIdx: req.pkgIdx, pkgSlot: req.pkgSlot, content: content
    )
  )

proc buildDetailCacheKey(req: WorkerReq): string {.inline.} =
  let versionLen =
    if req.source == SourceNimble:
      NimbleDetailFormatVersion.len + 1
    else:
      0
  result = newStringOfCap(req.pkgRepo.len + req.pkgName.len + req.pkgUrl.len + versionLen + 17)
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

proc ensureNimbleMetaLoaded(cacheRef: var PackedNimbleMetaCache): bool =
  ## Loads legacy Nimble package metadata for indexes that do not carry URLs.
  ## Current v6 `nimble.prix` files normally bypass this path.
  if cacheRef.entries.len > 0 and cacheRef.slots.len > 0:
    return true

  var nimbleCache = initNimbleCache()
  if not safeLoadOrRefreshCache(nimbleCache, keepJson = true):
    return false

  let jsonPath = getCachePath() / nimbleCache.jsonPath
  if not fileExists(jsonPath):
    discard ensureJsonAvailable(nimbleCache)
  if not fileExists(jsonPath):
    return false

  let loaded = loadPackedNimbleMeta(jsonPath)
  if loaded.entries.len == 0 or loaded.slots.len == 0:
    return false

  cacheRef = loaded
  true

proc tryFetchNimbleDetail(
    req: WorkerReq,
    nimbleMetaCache: var PackedNimbleMetaCache,
    client: HttpClient,
    content: var string,
): bool =
  ## Fetches and formats Nimble details from the package repository manifest.
  ## Returns false when neither an indexed URL nor legacy metadata can provide a
  ## usable repository URL, or when all candidate raw `.nimble` URLs fail.
  var metaUrl = req.pkgUrl
  var metaTagsLine = ""
  if metaUrl.len == 0:
    if not ensureNimbleMetaLoaded(nimbleMetaCache):
      return false
    if not getNimbleMeta(nimbleMetaCache, req.pkgName, metaUrl, metaTagsLine):
      return false

  for candidateUrl in getRawNimbleFileCandidates(metaUrl, req.pkgName):
    try:
      content = parseNimbleInfo(
        downloadWithRetry(client, candidateUrl, maxRetries = 2),
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
    nimbleMetaCache: var PackedNimbleMetaCache,
    toolDef: ToolDef,
    client: HttpClient,
) =
  ## Handles one detail request batch starting from `firstReq`.
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
