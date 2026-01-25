## Thread dedicated to blocking operations (I/O, Network, Subprocess execution).
## Abstracts differences between Pacman, Paru, Yay and Nimble.

import
  std/[
    os, osproc, strutils, strformat, tables, streams, sets, json, monotimes, httpclient,
    net, parseutils, times,
  ]
import ../core/types
import cache

type
  WorkerReqKind = enum
    ReqLoadAll
    ReqLoadNimble
    ReqLoadAur
    ReqSearch
    ReqDetails
    ReqStop

  WorkerReq = object
    kind: WorkerReqKind
    query, pkgName, pkgRepo: string
    pkgIdx: int32
    searchId: int
    source: DataSource
    targetMode: SearchMode
    targetSource: DataSource

  NimbleMeta = tuple[url: string, tags: seq[string]]

  PkgManagerType* = enum
    ManPacman
    ManParu
    ManYay
    ManNimble

  ToolDef = object
    bin*: string
    installCmd*: string
    uninstallCmd*: string
    searchCmd*: string
    sudo*: bool
    supportsAur*: bool

  ## Temporary accumulator for SoA data (Previously batcher.nim)
  BatchBuilder* = object
    soa*: PackageSOA
    textChunk*: string
    repos*: seq[string]
    repoMap*: Table[string, uint8]
    source: DataSource
    mode: SearchMode

func createPacmanToolDef(binName: string, withSudo: bool): ToolDef =
  ToolDef(
    bin: binName,
    installCmd: " -S ",
    uninstallCmd: " -R ",
    searchCmd: " -Ss ",
    sudo: withSudo,
    supportsAur: false,
  )

func createNimbleToolDef(): ToolDef =
  ToolDef(
    bin: "nimble",
    installCmd: " install ",
    uninstallCmd: " uninstall ",
    searchCmd: " search ",
    sudo: false,
    supportsAur: false,
  )

const Tools*: array[PkgManagerType, ToolDef] = [
  ManPacman: createPacmanToolDef("pacman", true),
  ManParu: createPacmanToolDef("paru", false),
  ManYay: createPacmanToolDef("yay", false),
  ManNimble: createNimbleToolDef(),
]

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[Msg]
  workerThread: Thread[PkgManagerType]
  activeTool*: PkgManagerType

func initBatchBuilder*(source: DataSource, mode: SearchMode): BatchBuilder =
  result.source = source
  result.mode = mode
  result.soa.hot.locators = newSeqOfCap[uint32](1000)
  result.soa.hot.nameLens = newSeqOfCap[uint8](1000)
  result.soa.cold.verLens = newSeqOfCap[uint8](1000)
  result.soa.cold.repoIndices = newSeqOfCap[uint8](1000)
  result.soa.cold.flags = newSeqOfCap[uint8](1000)

  result.textChunk = newStringOfCap(BatchSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch*(
    bb: var BatchBuilder,
    resChan: var Channel[Msg],
    searchId: int,
    startTime: MonoTime,
    force: bool = false,
) =
  if bb.soa.hot.locators.len > 0 or force:
    let dur = (getMonoTime() - startTime).inMilliseconds.int
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        soa: bb.soa,
        textChunk: bb.textChunk,
        repos: bb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
        reqSource: bb.source,
        reqMode: bb.mode,
      )
    )

    # Efficient reset
    bb.soa.hot.locators.setLen(0)
    bb.soa.hot.nameLens.setLen(0)
    bb.soa.cold.verLens.setLen(0)
    bb.soa.cold.repoIndices.setLen(0)
    bb.soa.cold.flags.setLen(0)

    bb.textChunk.setLen(0)
    bb.repos.setLen(0)
    bb.repoMap.clear()

func addPackage*(
    bb: var BatchBuilder, name, ver: openArray[char], repo: string, installed: bool
) =
  if bb.textChunk.len + name.len + ver.len > BatchSize:
    return

  var rIdx: uint8 = 0
  if bb.repoMap.hasKey(repo):
    rIdx = bb.repoMap[repo]
  else:
    if bb.repos.len < 255:
      rIdx = uint8(bb.repos.len)
      bb.repos.add(repo)
      bb.repoMap[repo] = rIdx
    else:
      rIdx = 0 # Fallback

  let offset = uint32(bb.textChunk.len)
  for c in name:
    bb.textChunk.add(c)
  for c in ver:
    bb.textChunk.add(c)

  bb.soa.hot.locators.add(offset)
  bb.soa.hot.nameLens.add(uint8(name.len))
  bb.soa.cold.verLens.add(uint8(ver.len))
  bb.soa.cold.repoIndices.add(rIdx)
  bb.soa.cold.flags.add(if installed: 1'u8 else: 0'u8)

func parseInstalledPackages*(output: string): Table[string, string] =
  # Inlined from utils/pacman.nim
  result = initTable[string, string]()
  for line in output.splitLines:
    let parts = line.split(' ')
    if parts.len > 1:
      result[parts[0]] = parts[1]

func isPackageInstalled*(line: string): bool =
  # Inlined from utils/pacman.nim
  return line.contains("[installed]") or line.contains("[instalado]")

func getRawBaseUrl*(repoUrl: string): string {.noSideEffect.} =
  # Inlined from utils/nimble.nim
  var cleanUrl = repoUrl.strip()
  if cleanUrl.endsWith(" (git)"):
    cleanUrl = cleanUrl[0 .. ^7]
  elif cleanUrl.endsWith(" (hg)"):
    cleanUrl = cleanUrl[0 .. ^6]

  if cleanUrl.endsWith(".git"):
    cleanUrl = cleanUrl[0 .. ^5]
  if cleanUrl.endsWith("/"):
    cleanUrl = cleanUrl[0 .. ^2]

  if "github.com" in cleanUrl:
    return cleanUrl.replace("github.com", "raw.githubusercontent.com")
  elif "codeberg.org" in cleanUrl:
    return cleanUrl & "/raw/branch"
  elif "gitlab.com" in cleanUrl:
    return cleanUrl & "/-/raw"
  elif "sr.ht" in cleanUrl:
    return cleanUrl & "/blob"
  return ""

func parseNimbleInfo*(
    raw, name, url: string, tags: seq[string]
): string {.noSideEffect.} =
  # Inlined from utils/nimble.nim
  var info = initTable[string, string]()
  var requires: seq[string] = @[]

  for line in raw.splitLines():
    let l = line.strip()
    if l.len == 0 or l.startsWith("#"):
      continue

    let lowerL = l.toLowerAscii()
    if lowerL.startsWith("requires"):
      var rest =
        if lowerL.startsWith("requires:"):
          l[9 ..^ 1].strip()
        else:
          l[8 ..^ 1].strip()
      if rest.startsWith("(") and rest.endsWith(")"):
        rest = rest[1 ..^ 2]
      for part in rest.split(','):
        let dep = part.strip().strip(chars = {'"'})
        if dep.len > 0:
          requires.add(dep)
    elif '=' in l:
      let parts = l.split('=', 1)
      let key = parts[0].strip().toLowerAscii()
      let val = parts[1].strip().strip(chars = {'"'})
      case key
      of "version":
        info["Version"] = val
      of "author":
        info["Author"] = val
      of "description":
        info["Description"] = val
      of "license":
        info["License"] = val
      else:
        discard

  # Normalize to pacman-style format with consistent field names and padding
  result = newStringOfCap(raw.len + 200)
  result.add("Name            : " & name & "\n")
  if info.hasKey("Version"):
    result.add("Version         : " & info["Version"] & "\n")
  if info.hasKey("Description"):
    result.add("Description     : " & info["Description"] & "\n")
  if info.hasKey("Author"):
    result.add("Author          : " & info["Author"] & "\n")
  if info.hasKey("License"):
    result.add("License         : " & info["License"] & "\n")
  if url.len > 0:
    result.add("URL             : " & url & "\n")
  if tags.len > 0:
    result.add("Tags            : " & tags.join(", ") & "\n")
  if requires.len > 0:
    result.add("Depends On      : " & requires.join(", ") & "\n")

func formatFallbackInfo*(raw: string): string {.noSideEffect.} =
  # Inlined from utils/nimble.nim
  var info = initTable[string, string]()
  for line in raw.splitLines():
    if line.strip().len == 0:
      continue
    if not line.startsWith(" ") and line.endsWith(":"):
      info["Name"] = line[0 ..^ 2]
    else:
      let l = line.strip()
      if ':' in l:
        let parts = l.split(':', 1)
        let key = parts[0].strip().toLowerAscii()
        let val = parts[1].strip()
        case key
        of "url":
          info["URL"] = val
        of "tags":
          info["Tags"] = val
        of "description":
          info["Description"] = val
        of "license":
          info["License"] = val
        of "version":
          info["Version"] = val
        of "author":
          info["Author"] = val
        else:
          discard

  result = newStringOfCap(raw.len + 100)
  # Only add fields that have values - normalize to pacman format
  if info.hasKey("Name"):
    result.add("Name            : " & info["Name"] & "\n")
  if info.hasKey("Version"):
    result.add("Version         : " & info["Version"] & "\n")
  if info.hasKey("Description"):
    result.add("Description     : " & info["Description"] & "\n")
  if info.hasKey("Author"):
    result.add("Author          : " & info["Author"] & "\n")
  if info.hasKey("License"):
    result.add("License         : " & info["License"] & "\n")
  if info.hasKey("URL"):
    result.add("URL             : " & info["URL"] & "\n")
  if info.hasKey("Tags"):
    result.add("Tags            : " & info["Tags"] & "\n")
  result.add("\n(Info from local nimble search cache)")

proc workerLoop(toolType: PkgManagerType) {.thread.} =
  ## Main loop of the worker thread.
  var currentReq: WorkerReq
  var hasReq = false
  var nimbleMetaCache = initTable[string, NimbleMeta]()
  var client = newHttpClient(timeout = 3000)
  let toolDef = Tools[toolType]

  var globalInstMap = initTable[string, string]()
  var instMapLoaded = false

  while true:
    if not hasReq:
      currentReq = reqChan.recv()
      hasReq = true
    let req = currentReq
    hasReq = false

    try:
      case req.kind
      of ReqStop:
        client.close()
        break
      of ReqLoadAll:
        let tStart = getMonoTime()
        # Refresh installed cache only on explicit reload all
        let (instOut, _) = execCmdEx("pacman -Q")
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
        var interrupted = false
        var lastRepo = ""

        while outp.readLine(line):
          if line.len == 0:
            continue
          var i = 0

          # Parse Repo (optimized)
          let repoLen = line.skipUntil(' ', i)
          let repoStart = i
          i += repoLen
          i += line.skipWhitespace(i)

          # Check if repo changed to reuse string
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

          # Parse Name
          let nameLen = line.skipUntil(' ', i)
          let nameStart = i
          i += nameLen
          i += line.skipWhitespace(i)

          # Parse Ver
          let verLen = line.skipUntil(' ', i)
          let verStart = i

          if bb.textChunk.len + nameLen + verLen > BatchSize or counter >= 1000:
            flushBatch(bb, resChan, req.searchId, tStart)
            counter = 0

          var installed = isPackageInstalled(line)
          if not installed:
            let nameStr = line[nameStart ..< nameStart + nameLen]
            if globalInstMap.hasKey(nameStr):
              installed = true

          bb.addPackage(
            line.toOpenArray(nameStart, nameStart + nameLen - 1),
            line.toOpenArray(verStart, verStart + verLen - 1),
            repoStr,
            installed,
          )
          counter.inc()
        p.close()
        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqLoadNimble:
        let tStart = getMonoTime()
        var installedSet = initHashSet[string]()
        let (listOut, _) = execCmdEx("nimble list -i --noColor")
        for line in listOut.splitLines:
          let parts = line.split(' ')
          if parts.len > 0:
            installedSet.incl(parts[0])

        var nimbleCache = initNimbleCache()
        # Ensure we keep the JSON for metadata extraction
        if not loadOrRefreshCache(nimbleCache, keepJson = true):
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to load Nimble metadata"))
          continue

        let jsonPath = getCachePath() / nimbleCache.jsonPath

        # If cache was fresh but JSON was missing (from previous run), fetch it
        if not fileExists(jsonPath):
          discard ensureJsonAvailable(nimbleCache)

        if fileExists(jsonPath):
          nimbleMetaCache = getStreamedNimbleMeta(jsonPath)

        let binPath = getCachePath() / nimbleCache.binPath
        var bb = initBatchBuilder(SourceNimble, ModeLocal)
        var counter = 0
        var interrupted = false
        var nameBuf = newStringOfCap(256)

        withBinaryCache(binPath, name, version):
          if bb.textChunk.len + name.len + version.len > BatchSize or counter >= 2000:
            flushBatch(bb, resChan, req.searchId, tStart)
            counter = 0

          if not interrupted:
            nameBuf.setLen(name.len)
            for i in 0 ..< name.len:
              nameBuf[i] = name[i]
            bb.addPackage(name, version, "nimble", nameBuf in installedSet)
            counter.inc()

        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqLoadAur:
        let tStart = getMonoTime()
        var aurCache = initAurCache()
        if not loadOrRefreshCache(aurCache):
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to load AUR metadata"))
          continue

        if not instMapLoaded:
          let (instOut, _) = execCmdEx("pacman -Q")
          globalInstMap = parseInstalledPackages(instOut)
          instMapLoaded = true

        let binPath = getCachePath() / aurCache.binPath
        var bb = initBatchBuilder(SourceSystem, ModeAUR)
        var counter = 0
        var interrupted = false
        var nameBuf = newStringOfCap(256)

        withBinaryCache(binPath, name, version):
          if bb.textChunk.len + name.len + version.len > BatchSize or counter >= 5000:
            flushBatch(bb, resChan, req.searchId, tStart)
            counter = 0

          if not interrupted:
            nameBuf.setLen(name.len)
            for i in 0 ..< name.len:
              nameBuf[i] = name[i]
            bb.addPackage(name, version, "aur", globalInstMap.hasKey(nameBuf))
            counter.inc()

        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqSearch:
        let tStart = getMonoTime()
        if not instMapLoaded:
          let (instOut, _) = execCmdEx("pacman -Q")
          globalInstMap = parseInstalledPackages(instOut)
          instMapLoaded = true

        let (outp, _) = execCmdEx(toolDef.bin & toolDef.searchCmd & req.query)
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
          if bb.textChunk.len + name.len + ver.len > BatchSize:
            flushBatch(bb, resChan, req.searchId, tStart)

          bb.addPackage(name, ver, repo, globalInstMap.hasKey(name))
        flushBatch(bb, resChan, req.searchId, tStart)
      of ReqDetails:
        if req.source == SourceNimble:
          var content = ""
          var fetched = false
          if nimbleMetaCache.hasKey(req.pkgName):
            let meta = nimbleMetaCache[req.pkgName]
            let rawBase = getRawBaseUrl(meta.url)
            if rawBase.len > 0:
              var names = @[req.pkgName]
              if req.pkgName != req.pkgName.toLowerAscii():
                names.add(req.pkgName.toLowerAscii())
              for branch in ["master", "main"]:
                for nameVariant in names:
                  try:
                    content = parseNimbleInfo(
                      client.getContent(
                        rawBase & "/" & branch & "/" & nameVariant & ".nimble"
                      ),
                      req.pkgName,
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
            resChan.send(
              Msg(kind: MsgDetailsLoaded, pkgIdx: req.pkgIdx, content: content)
            )
          else:
            let (c, _) = execCmdEx("nimble search " & req.pkgName)
            resChan.send(
              Msg(
                kind: MsgDetailsLoaded,
                pkgIdx: req.pkgIdx,
                content: formatFallbackInfo(c),
              )
            )
        else:
          let target =
            if req.pkgRepo == "local":
              req.pkgName
            else:
              fmt"{req.pkgRepo}/{req.pkgName}"
          let bin = if req.pkgRepo == "local": "pacman" else: toolDef.bin
          let args =
            if req.pkgRepo == "local":
              @["-Qi", target]
            else:
              @["-Si", target]
          let (c, _) = execCmdEx(bin & " " & args.join(" "))
          resChan.send(Msg(kind: MsgDetailsLoaded, pkgIdx: req.pkgIdx, content: c))
    except Exception as e:
      resChan.send(Msg(kind: MsgError, errMsg: e.msg))

proc initPackageManager*() =
  ## Initializes the worker thread and detects package manager (paru/yay/pacman).
  reqChan.open()
  resChan.open()

  if findExe("paru").len > 0:
    activeTool = ManParu
  elif findExe("yay").len > 0:
    activeTool = ManYay
  else:
    activeTool = ManPacman

  createThread(workerThread, workerLoop, activeTool)

proc shutdownPackageManager*() =
  ## Stops the worker thread and closes channels.
  reqChan.send(WorkerReq(kind: ReqStop))
  reqChan.close()
  resChan.close()

proc requestLoadAll*(id: int) =
  reqChan.send(WorkerReq(kind: ReqLoadAll, searchId: id))

proc requestLoadAur*(id: int) =
  reqChan.send(WorkerReq(kind: ReqLoadAur, searchId: id))

proc requestLoadNimble*(id: int) =
  reqChan.send(WorkerReq(kind: ReqLoadNimble, searchId: id))

proc requestSearch*(query: string, id: int) =
  reqChan.send(WorkerReq(kind: ReqSearch, query: query, searchId: id))

proc requestDetails*(idx: int32, name, repo: string, source: DataSource) =
  reqChan.send(
    WorkerReq(
      kind: ReqDetails, pkgIdx: idx, pkgName: name, pkgRepo: repo, source: source
    )
  )

proc pollWorkerMessages*(): seq[Msg] =
  ## Retrieves all pending messages from the worker (non-blocking).
  result = @[]
  while true:
    (let (ok, msg) = resChan.tryRecv(); if not ok: break ; result.add(msg))

func buildCmd*(tool: PkgManagerType, op: string, targets: seq[string]): string =
  let def = Tools[tool]
  let prefix = if def.sudo and tool != ManNimble: "sudo " else: ""
  result = prefix & def.bin & op & targets.join(" ")

proc runTransaction*(tool: PkgManagerType, targets: seq[string], install: bool): int =
  if targets.len == 0:
    return 0
  let def = Tools[tool]
  let op = if install: def.installCmd else: def.uninstallCmd
  let cmd = buildCmd(tool, op, targets)
  return execCmd(cmd)

proc installPackages*(names: seq[string], source: DataSource): int =
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, true)

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, false)
