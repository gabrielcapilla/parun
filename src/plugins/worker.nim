import std/[os, osproc, strutils, streams, monotimes, httpclient, parseutils]
import ../core/types
import ../utils/memory_accounting
import cache, worker_types
import contracts
import pacman
import worker_cache
import worker_exec, worker_details

proc buildWorkerMemoryReport(
    detailsCache: PackedDetailCache,
    nimbleMetaCache: PackedNimbleMetaCache,
    globalInstMap: PackedInstalledMap,
    detailBatch: seq[WorkerReq],
    client: HttpClient,
): WorkerMemoryReport =
  var cacheSection = MemorySection(name: "worker_caches")
  cacheSection.addMetric(
    "details_cache",
    detailsCacheBytes(detailsCache),
    detailsCache.count,
    WorkerDetailsCacheLimit,
    "Worker-side detail text cache (packed metadata + arena)",
  )
  cacheSection.addMetric(
    "nimble_meta_cache",
    nimbleMetaCacheBytes(nimbleMetaCache),
    nimbleMetaCache.entries.len,
    nimbleMetaCache.slots.len,
    "Cached Nimble package metadata (packed hash index + arena)",
  )
  cacheSection.addMetric(
    "installed_package_map",
    installedMapBytes(globalInstMap),
    globalInstMap.entries.len,
    globalInstMap.slots.len,
    "Installed package lookup map (packed hash index + arena)",
  )
  cacheSection.addSeqMetric(
    "detail_batch", detailBatch, "Pending detail requests coalesced in worker"
  )

  var runtimeSection = MemorySection(name: "worker_runtime")
  runtimeSection.addScalarMetric(
    "http_client_struct",
    sizeof(client),
    "HttpClient object size only; stdlib internals not expanded",
  )

  result.sections = @[cacheSection, runtimeSection]

proc workerLoop*(
    toolType: PkgManagerType, reqChan: var Channel[WorkerReq], resChan: var Channel[Msg]
) {.thread.} =
  ## Main loop of the worker thread.
  var currentReq: WorkerReq
  var hasReq = false
  var nimbleMetaCache = PackedNimbleMetaCache()
  var detailsCache = initDetailsCache() # Worker-side persistent cache
  # HTTP client with default SSL certificate validation
  # Note: Nim's httpclient validates certificates by default
  var client = newHttpClient(timeout = 3000)
  let toolDef = getToolDef(toolType)
  if toolDef.source != SourceSystem:
    resChan.send(
      Msg(
        kind: MsgError,
        errMsg: "Invalid active plugin source for worker: " & toolDef.key,
      )
    )
    client.close()
    return
  enforceCapabilities(
    toolDef, {capSearch, capDetails, capSystemCatalog, capAurCatalog}, "worker loop"
  )

  var globalInstMap = PackedInstalledMap()
  var instMapLoaded = false
  var detailBatch = newSeqOfCap[WorkerReq](16)

  while true:
    if not hasReq:
      currentReq = reqChan.recv()
    else:
      hasReq = false

    let req = currentReq

    try:
      case req.kind
      of ReqStop:
        client.close()
        break
      of ReqDiagnostics:
        resChan.send(
          Msg(
            kind: MsgWorkerDiagnostics,
            workerReport: buildWorkerMemoryReport(
              detailsCache, nimbleMetaCache, globalInstMap, detailBatch, client
            ),
          )
        )
      of ReqLoadAll:
        let tStart = getMonoTime()
        let (instOut, exitCode) = execCmdEx("pacman -Q")
        if exitCode != 0:
          resChan.send(
            Msg(
              kind: MsgError,
              errMsg: "Failed to get installed packages (pacman -Q failed)",
            )
          )
          continue
        globalInstMap = parseInstalledPackagesPacked(instOut)
        instMapLoaded = true

        var p = startProcess(
          "pacman",
          args = ["-Sl", "--color", "never"],
          options = {poUsePath, poStdErrToStdOut},
        )
        var outp = p.outputStream
        var line = ""
        var bb = initBatchBuilder(SourceSystem, ModeLocal)
        var counter = 0
        var lastRepo = ""

        while outp.readLine(line):
          if line.len == 0:
            continue
          var i = 0
          let repoLen = line.skipUntil(' ', i)
          let repoStart = i
          i += repoLen
          i += line.skipWhitespace(i)

          var repoStr = lastRepo
          var match = true
          if repoLen != lastRepo.len:
            match = false
          else:
            for k in 0 ..< repoLen:
              if line[repoStart + k] != lastRepo[k]:
                match = false
                break

          if not match:
            repoStr = line[repoStart ..< repoStart + repoLen]
            lastRepo = repoStr

          let nameLen = line.skipUntil(' ', i)
          let nameStart = i
          i += nameLen
          i += line.skipWhitespace(i)

          let verLen = line.skipUntil(' ', i)
          let verStart = i

          if bb.textChunk.len + nameLen + verLen > worker_types.BatchSize or
              counter >= 1000:
            bb.flushBatch(resChan, req.searchId, tStart)
            counter = 0

          var installed = isPackageInstalled(line)
          if not installed and nameLen > 0:
            if containsInstalledMap(
              globalInstMap, line.toOpenArray(nameStart, nameStart + nameLen - 1)
            ):
              installed = true

          addPackage(
            bb,
            line.toOpenArray(nameStart, nameStart + nameLen - 1),
            line.toOpenArray(verStart, verStart + verLen - 1),
            repoStr,
            installed,
          )
          counter.inc()
        p.close()
        bb.flushBatch(resChan, req.searchId, tStart)
      of ReqLoadNimble:
        let tStart = getMonoTime()
        var nimbleInstalled = PackedInstalledMap()
        let (listOut, listSuccess) =
          execWithErrorCheck("nimble list -i --noColor", emLenient)
        if listSuccess:
          nimbleInstalled = parseInstalledPackagesPacked(listOut)

        var nimbleCache = initNimbleCache()
        if not safeLoadOrRefreshCache(nimbleCache, keepJson = true):
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to load Nimble metadata"))
          continue

        let jsonPath = getCachePath() / nimbleCache.jsonPath
        if not fileExists(jsonPath):
          discard ensureJsonAvailable(nimbleCache)

        if fileExists(jsonPath):
          nimbleMetaCache = loadPackedNimbleMeta(jsonPath)

        let binPath = getCachePath() / nimbleCache.binPath
        var bb = initBatchBuilder(SourceNimble, ModeLocal)
        var counter = 0

        withBinaryCache(binPath, name, version):
          if bb.textChunk.len + name.len + version.len > worker_types.BatchSize or
              counter >= 2000:
            bb.flushBatch(resChan, req.searchId, tStart)
            counter = 0

          addPackage(
            bb, name, version, "nimble", containsInstalledMap(nimbleInstalled, name)
          )
          counter.inc()

        bb.flushBatch(resChan, req.searchId, tStart)
      of ReqLoadAur:
        let tStart = getMonoTime()
        var aurCache = initAurCache()
        if not safeLoadOrRefreshCache(aurCache):
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to load AUR metadata"))
          continue

        if not instMapLoaded:
          let (instOut, instSuccess) = execWithErrorCheck("pacman -Q", emStrict)
          if not instSuccess:
            resChan.send(
              Msg(kind: MsgError, errMsg: "Failed to get installed packages")
            )
            continue
          globalInstMap = parseInstalledPackagesPacked(instOut)
          instMapLoaded = true

        let binPath = getCachePath() / aurCache.binPath
        var bb = initBatchBuilder(SourceSystem, ModeAUR)
        var counter = 0
        var nameBuf = newStringOfCap(256)

        withBinaryCache(binPath, name, version):
          if bb.textChunk.len + name.len + version.len > worker_types.BatchSize or
              counter >= 5000:
            bb.flushBatch(resChan, req.searchId, tStart)
            counter = 0

          nameBuf.setLen(name.len)
          for i in 0 ..< name.len:
            nameBuf[i] = name[i]
          addPackage(
            bb, name, version, "aur", containsInstalledMap(globalInstMap, name)
          )
          counter.inc()

        bb.flushBatch(resChan, req.searchId, tStart)
      of ReqSearch:
        let tStart = getMonoTime()
        if not instMapLoaded:
          let (instOut, instOk) = execWithErrorCheck("pacman -Q", emStrict)
          if not instOk:
            resChan.send(
              Msg(kind: MsgError, errMsg: "Failed to list installed packages")
            )
            continue
          globalInstMap = parseInstalledPackagesPacked(instOut)
          instMapLoaded = true

        let (outp, _) =
          execWithErrorCheck(toolDef.bin & toolDef.searchCmd & req.query, emLenient)
        var bb = initBatchBuilder(SourceSystem, ModeLocal)
        for line in outp.split('\n'):
          if line.len == 0:
            continue
          var i = 0
          var fullId, ver: string
          i += line.parseUntil(fullId, ' ', i)
          var repo = "unknown"
          var name = fullId
          if '/' in fullId:
            let s = fullId.split('/', 1)
            repo = s[0]
            name = s[1]
          i += line.skipWhitespace(i)
          i += line.parseUntil(ver, ' ', i)
          if bb.textChunk.len + name.len + ver.len > worker_types.BatchSize:
            bb.flushBatch(resChan, req.searchId, tStart)

          addPackage(bb, name, ver, repo, containsInstalledMap(globalInstMap, name))
        bb.flushBatch(resChan, req.searchId, tStart)
      of ReqDetails:
        processDetailRequests(
          req, reqChan, resChan, currentReq, hasReq, detailBatch, detailsCache,
          nimbleMetaCache, toolDef, client,
        )
    except Exception as e:
      resChan.send(Msg(kind: MsgError, errMsg: e.msg))
