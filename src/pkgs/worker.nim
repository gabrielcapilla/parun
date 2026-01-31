import
  std/
    [
      os, osproc, strutils, tables, streams, sets, monotimes, httpclient, net,
      parseutils,
    ]
import ../core/types
import cache, worker_types
import backends/[pacman, nimble]

proc downloadWithRetry*(client: HttpClient, url: string, maxRetries: int = 3): string =
  ## Downloads content with exponential backoff retry logic
  var lastError: string = ""
  for i in 0 ..< maxRetries:
    try:
      return client.getContent(url)
    except Exception as e:
      lastError = e.msg
      if i < maxRetries - 1:
        let delay = 1000 * (i + 1) # Exponential backoff: 1s, 2s, 3s
        sleep(delay)
  # All retries failed
  raise newException(
    HttpRequestError,
    "Failed to download after " & $maxRetries & " attempts: " & lastError,
  )

proc addToDetailsCache(
    cache: var Table[string, string], key, value: string, maxSize: int
) =
  ## Adds item to cache with LRU-style eviction when limit reached
  if cache.len >= maxSize:
    # Simple eviction: clear half the cache when full
    var count = 0
    for k in cache.keys:
      if count < maxSize div 2:
        cache.del(k)
        count += 1
      else:
        break
  cache[key] = value

type
  ExecResult = tuple[output: string, success: bool]
  ExecMode = enum
    emStrict ## Non-zero exit code = failure (for critical commands)
    emLenient ## Empty output is acceptable even with non-zero (for search)

proc execWithErrorCheck(cmd: string, mode: ExecMode = emStrict): ExecResult =
  ## Executes command with appropriate error handling based on mode
  ## emStrict: Any non-zero exit code is failure
  ## emLenient: Empty output with non-zero is acceptable (no results)
  let (output, exitCode) = execCmdEx(cmd)

  case mode
  of emStrict:
    if exitCode != 0:
      return ("", false)
  of emLenient:
    # For search commands: empty result is OK, only fail if command itself failed
    # We still return output even if exitCode != 0 (could mean "no results")
    discard

  return (output, true)

proc workerLoop*(
    toolType: PkgManagerType,
    reqChan: var Channel[WorkerReq],
    resChan: var Channel[Msg],
    tools: array[PkgManagerType, ToolDef],
) {.thread.} =
  ## Main loop of the worker thread.
  var currentReq: WorkerReq
  var hasReq = false
  var nimbleMetaCache = initTable[string, NimbleMeta]()
  var detailsCache = initTable[string, string]() # Worker-side persistent cache
  const MaxDetailsCacheSize = 512 # Prevent memory leak in long sessions
  # HTTP client with default SSL certificate validation
  # Note: Nim's httpclient validates certificates by default
  var client = newHttpClient(timeout = 3000)
  let toolDef = tools[toolType]

  var globalInstMap = initTable[string, string]()
  var instMapLoaded = false

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
        globalInstMap = parseInstalledPackages(instOut)
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
          if not installed:
            let nameStr = line[nameStart ..< nameStart + nameLen]
            if globalInstMap.hasKey(nameStr):
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
        var installedSet = initHashSet[string]()
        let (listOut, listSuccess) =
          execWithErrorCheck("nimble list -i --noColor", emLenient)
        if listSuccess:
          for line in listOut.splitLines:
            let parts = line.split(' ')
            if parts.len > 0:
              installedSet.incl(parts[0])

        var nimbleCache = initNimbleCache()
        if not safeLoadOrRefreshCache(nimbleCache, keepJson = true):
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to load Nimble metadata"))
          continue

        let jsonPath = getCachePath() / nimbleCache.jsonPath
        if not fileExists(jsonPath):
          discard ensureJsonAvailable(nimbleCache)

        if fileExists(jsonPath):
          nimbleMetaCache = getStreamedNimbleMeta(jsonPath)

        let binPath = getCachePath() / nimbleCache.binPath
        var bb = initBatchBuilder(SourceNimble, ModeLocal)
        var counter = 0
        var nameBuf = newStringOfCap(256)

        withBinaryCache(binPath, name, version):
          if bb.textChunk.len + name.len + version.len > worker_types.BatchSize or
              counter >= 2000:
            bb.flushBatch(resChan, req.searchId, tStart)
            counter = 0

          nameBuf.setLen(name.len)
          for i in 0 ..< name.len:
            nameBuf[i] = name[i]
          addPackage(bb, name, version, "nimble", nameBuf in installedSet)
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
          globalInstMap = parseInstalledPackages(instOut)
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
          addPackage(bb, name, version, "aur", globalInstMap.hasKey(nameBuf))
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
          globalInstMap = parseInstalledPackages(instOut)
          instMapLoaded = true

        let (outp, _) =
          execWithErrorCheck(toolDef.bin & toolDef.searchCmd & req.query, emLenient)
        var bb = initBatchBuilder(SourceSystem, ModeLocal)
        for line in outp.splitLines:
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

          addPackage(bb, name, ver, repo, globalInstMap.hasKey(name))
        bb.flushBatch(resChan, req.searchId, tStart)
      of ReqDetails:
        var batch = @[req]
        while batch.len < 16:
          let (ok, nextReq) = reqChan.tryRecv()
          if ok:
            if nextReq.kind == ReqDetails:
              batch.add(nextReq)
            else:
              currentReq = nextReq
              hasReq = true
              break
          else:
            break

        for r in batch:
          let cacheKey = $r.source & ":" & r.pkgRepo & ":" & r.pkgName
          if detailsCache.hasKey(cacheKey):
            resChan.send(
              Msg(
                kind: MsgDetailsLoaded,
                pkgIdx: r.pkgIdx,
                content: detailsCache[cacheKey],
              )
            )
            continue

          if r.source == SourceNimble:
            var content = ""
            var fetched = false
            if nimbleMetaCache.hasKey(r.pkgName):
              let meta = nimbleMetaCache[r.pkgName]
              let rawBase = getRawBaseUrl(meta.url)
              if rawBase.len > 0:
                var names = @[r.pkgName]
                if r.pkgName != r.pkgName.toLowerAscii():
                  names.add(r.pkgName.toLowerAscii())
                for branch in ["master", "main"]:
                  for nameVariant in names:
                    try:
                      content = parseNimbleInfo(
                        downloadWithRetry(
                          client,
                          rawBase & "/" & branch & "/" & nameVariant & ".nimble",
                          maxRetries = 2, # Shorter retries for speculative fetches
                        ),
                        r.pkgName,
                        meta.url,
                        meta.tags,
                      )
                      fetched = true
                      break
                    except:
                      continue
                  if fetched:
                    break

            if fetched:
              addToDetailsCache(detailsCache, cacheKey, content, MaxDetailsCacheSize)
              resChan.send(
                Msg(kind: MsgDetailsLoaded, pkgIdx: r.pkgIdx, content: content)
              )
            else:
              let (c, _) = execWithErrorCheck("nimble search " & r.pkgName, emLenient)
              let info = formatFallbackInfo(c)
              addToDetailsCache(detailsCache, cacheKey, info, MaxDetailsCacheSize)
              resChan.send(Msg(kind: MsgDetailsLoaded, pkgIdx: r.pkgIdx, content: info))
          else:
            let target =
              if r.pkgRepo == "local":
                r.pkgName
              else:
                r.pkgRepo & "/" & r.pkgName
            let bin = if r.pkgRepo == "local": "pacman" else: toolDef.bin
            let args =
              if r.pkgRepo == "local":
                @["-Qi", target]
              else:
                @["-Si", target]
            let (c, ok) = execWithErrorCheck(bin & " " & args.join(" "), emStrict)
            if not ok:
              resChan.send(
                Msg(
                  kind: MsgError, errMsg: "Failed to get package info for " & r.pkgName
                )
              )
              continue
            addToDetailsCache(detailsCache, cacheKey, c, MaxDetailsCacheSize)
            resChan.send(Msg(kind: MsgDetailsLoaded, pkgIdx: r.pkgIdx, content: c))
    except Exception as e:
      resChan.send(Msg(kind: MsgError, errMsg: e.msg))
