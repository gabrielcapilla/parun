## Thread dedicated to blocking operations (I/O, Network, Subprocess execution).
## Abstracts differences between Pacman, Paru, Yay and Nimble.

# This module is very extensive and has a lot of features.
# I should make an effort to divide the code and even create new modules.

import
  std/[
    os, osproc, strutils, strformat, tables, streams, sets, parsejson, monotimes,
    httpclient, net, parseutils, times,
  ]
import types, batcher, nUtils, pUtils

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

const
  AurMetaUrl* = "https://aur.archlinux.org/packages-meta-v1.json.gz"
  NimbleMetaUrl* =
    "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"
  CacheMaxAgeHours* = 24

## Definition of a cacheable JSON data source.
type CachedJsonSource* = object
  localFallbackPath*: string
  cachePath*: string
  url*: string
  maxAgeHours*: int
  isCompressed*: bool

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[Msg]
  workerThread: Thread[PkgManagerType]
  activeTool*: PkgManagerType

proc downloadJsonToCache*(url, cachePath: string): bool =
  ## Downloads a JSON file using native httpclient.
  var client = newHttpClient(timeout = 30_000)
  try:
    client.downloadFile(url, cachePath)
    client.close()
    return true
  except Exception:
    client.close()
    return false

proc getFreshJsonPath*(
    source: CachedJsonSource
): tuple[path: string, wasDownloaded: bool] =
  ## Gets path to a valid JSON, downloading if necessary or if cache expired.
  let cacheDir = getHomeDir() / ".cache/parun"
  createDir(cacheDir)

  let actualCachePath = cacheDir / source.cachePath

  var bestPath = ""
  var ageHours = high(int)

  if fileExists(actualCachePath):
    let info = getFileInfo(actualCachePath)
    ageHours = (getTime() - info.lastWriteTime).inHours
    if ageHours < source.maxAgeHours:
      bestPath = actualCachePath

  if bestPath.len == 0 and source.localFallbackPath.len > 0:
    if fileExists(source.localFallbackPath):
      let info = getFileInfo(source.localFallbackPath)
      let localAge = (getTime() - info.lastWriteTime).inHours
      if localAge < source.maxAgeHours:
        bestPath = source.localFallbackPath
        ageHours = localAge

  var wasDownloaded = false
  if bestPath.len == 0 or ageHours >= source.maxAgeHours:
    if downloadJsonToCache(source.url, actualCachePath):
      bestPath = actualCachePath
      wasDownloaded = true
    elif source.localFallbackPath.len > 0 and fileExists(source.localFallbackPath):
      bestPath = source.localFallbackPath

  return (bestPath, wasDownloaded)

proc skipJsonBlock(p: var JsonParser) =
  ## Skips a full JSON block (object or array) efficiently.
  var depth = 1
  while depth > 0:
    p.next()
    case p.kind
    of jsonObjectStart, jsonArrayStart:
      inc depth
    of jsonObjectEnd, jsonArrayEnd:
      dec depth
    of jsonError, jsonEof:
      break
    else:
      discard

proc workerLoop(toolType: PkgManagerType) {.thread.} =
  ## Main loop of the worker thread.
  var currentReq: WorkerReq
  var hasReq = false
  var nimbleMetaCache = initTable[string, NimbleMeta]()
  var client = newHttpClient(timeout = 3000)
  let toolDef = Tools[toolType]

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
        # Load system packages (pacman -Sl)
        let tStart = getMonoTime()
        let (instOut, _) = execCmdEx("pacman -Q")
        let instMap = parseInstalledPackages(instOut)

        var p = startProcess(
          "pacman",
          args = ["-Sl", "--color", "never"],
          options = {poUsePath, poStdErrToStdOut},
        )
        var outp = p.outputStream
        var line = ""
        var bb = initBatchBuilder()
        var counter = 0
        var interrupted = false

        while outp.readLine(line):
          if line.len == 0:
            continue
          var i = 0
          var repo, name, ver: string
          i += line.parseUntil(repo, ' ', i)
          i += line.skipWhitespace(i)
          i += line.parseUntil(name, ' ', i)
          i += line.skipWhitespace(i)
          i += line.parseUntil(ver, ' ', i)

          if bb.textChunk.len + name.len + ver.len > BatchSize or counter >= 1000:
            flushBatch(bb, resChan, req.searchId, tStart)
            counter = 0
            let (hasNew, newReq) = reqChan.tryRecv()
            if hasNew and newReq.kind != ReqDetails:
              currentReq = newReq
              hasReq = true
              interrupted = true
              break

          bb.addPackage(
            name, ver, repo, instMap.hasKey(name) or isPackageInstalled(line)
          )
          counter.inc()
        p.close()
        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqLoadNimble:
        # Load Nimble packages from JSON
        let tStart = getMonoTime()
        var installedSet = initHashSet[string]()
        let (listOut, _) = execCmdEx("nimble list -i --noColor")
        for line in listOut.splitLines:
          let parts = line.split(' ')
          if parts.len > 0:
            installedSet.incl(parts[0])

        let nimbleSource = CachedJsonSource(
          localFallbackPath: getHomeDir() / ".nimble/packages_official.json",
          cachePath: "nimble-packages.json",
          url: NimbleMetaUrl,
          maxAgeHours: CacheMaxAgeHours,
          isCompressed: false,
        )

        let (pkgFile, _) = getFreshJsonPath(nimbleSource)
        if pkgFile.len == 0:
          resChan.send(
            Msg(
              kind: MsgError,
              errMsg:
                "No Nimble packages available (download failed and no local cache)",
            )
          )
          continue

        var fs = newFileStream(pkgFile, fmRead)
        var parser: JsonParser
        open(parser, fs, pkgFile)
        defer:
          close(parser)
        var bb = initBatchBuilder()
        var counter = 0
        var interrupted = false
        nimbleMetaCache.clear()
        parser.next()

        while parser.kind != jsonEof and parser.kind != jsonError:
          if parser.kind == jsonObjectStart:
            var name, version, url = ""
            var tags: seq[string] = @[]
            parser.next()
            while parser.kind != jsonObjectEnd and parser.kind != jsonEof:
              if parser.kind == jsonString:
                let key = parser.str
                parser.next()
                if key == "name" and parser.kind == jsonString:
                  name = parser.str
                  parser.next()
                elif key == "version" and parser.kind == jsonString:
                  version = parser.str
                  parser.next()
                elif key == "url" and parser.kind == jsonString:
                  url = parser.str
                  parser.next()
                elif key == "tags" and parser.kind == jsonArrayStart:
                  parser.next()
                  while parser.kind != jsonArrayEnd:
                    if parser.kind == jsonString:
                      tags.add(parser.str)
                    parser.next()
                  parser.next()
                else:
                  if parser.kind in {jsonObjectStart, jsonArrayStart}:
                    skipJsonBlock(parser)
                    parser.next()
                  else:
                    parser.next()
              else:
                parser.next()

            if name.len > 0:
              let ver = if version.len > 0: version else: "latest"
              if url.len > 0:
                nimbleMetaCache[name] = (url: url, tags: tags)
              if bb.textChunk.len + name.len + ver.len > BatchSize or counter >= 500:
                flushBatch(bb, resChan, req.searchId, tStart)
                counter = 0
                let (hasNew, newReq) = reqChan.tryRecv()
                if hasNew and newReq.kind != ReqDetails:
                  currentReq = newReq
                  hasReq = true
                  interrupted = true
                  break
              bb.addPackage(name, ver, "nimble", name in installedSet)
              counter.inc()
            parser.next()
          else:
            parser.next()
        fs.close()
        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqLoadAur:
        # Load AUR packages from compressed JSON
        let tStart = getMonoTime()
        let aurSource = CachedJsonSource(
          localFallbackPath: "",
          cachePath: "aur-packages-meta-v1.json.gz",
          url: AurMetaUrl,
          maxAgeHours: CacheMaxAgeHours,
          isCompressed: true,
        )

        let (metaPath, _) = getFreshJsonPath(aurSource)
        if metaPath.len == 0:
          resChan.send(Msg(kind: MsgError, errMsg: "Failed to download AUR metadata"))
          continue

        let (instOut, _) = execCmdEx("pacman -Q")
        let instMap = parseInstalledPackages(instOut)

        var p = startProcess(
          "sh",
          args = ["-c", "gunzip -c " & metaPath],
          options = {poUsePath, poStdErrToStdOut},
        )
        var outp = p.outputStream

        var parser: JsonParser
        open(parser, outp, "aur_meta")
        defer:
          close(parser)

        var bb = initBatchBuilder()
        var counter = 0
        var interrupted = false

        parser.next()
        while parser.kind != jsonEof and parser.kind != jsonError:
          if parser.kind == jsonObjectStart:
            var name, ver: string
            parser.next()
            while parser.kind != jsonObjectEnd and parser.kind != jsonEof:
              if parser.kind == jsonString:
                let key = parser.str
                parser.next()
                if key == "Name" and parser.kind == jsonString:
                  name = parser.str
                  parser.next()
                elif key == "Version" and parser.kind == jsonString:
                  ver = parser.str
                  parser.next()
                else:
                  if parser.kind in {jsonObjectStart, jsonArrayStart}:
                    skipJsonBlock(parser)
                    parser.next()
                  else:
                    parser.next()
              else:
                parser.next()

            if name.len > 0:
              if bb.textChunk.len + name.len + ver.len > BatchSize or counter >= 2000:
                flushBatch(bb, resChan, req.searchId, tStart)
                counter = 0
                let (hasNew, newReq) = reqChan.tryRecv()
                if hasNew and newReq.kind != ReqDetails:
                  currentReq = newReq
                  hasReq = true
                  interrupted = true
                  break
              bb.addPackage(name, ver, "aur", instMap.hasKey(name))
              counter.inc()
            parser.next()
          else:
            parser.next()

        p.close()
        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqSearch:
        # Direct search (fallback for pacman -Ss)
        let tStart = getMonoTime()
        let (instOut, _) = execCmdEx("pacman -Q")
        let instMap = parseInstalledPackages(instOut)

        let (outp, _) = execCmdEx(toolDef.bin & toolDef.searchCmd & req.query)
        var bb = initBatchBuilder()
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

          bb.addPackage(name, ver, repo, instMap.hasKey(name))
        flushBatch(bb, resChan, req.searchId, tStart)
      of ReqDetails:
        # Load details (pacman -Si / nimble search)
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

func buildCmd(tool: PkgManagerType, op: string, targets: seq[string]): string =
  let def = Tools[tool]
  let prefix = if def.sudo and tool != ManNimble: "sudo " else: ""
  result = prefix & def.bin & op & targets.join(" ")

proc runTransaction(tool: PkgManagerType, targets: seq[string], install: bool): int =
  if targets.len == 0:
    return 0
  let def = Tools[tool]
  let op = if install: def.installCmd else: def.uninstallCmd
  let cmd = buildCmd(tool, op, targets)
  return execCmd(cmd)

proc installPackages*(names: seq[string], source: DataSource): int =
  ## Executes the install command in the main terminal.
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, true)

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  ## Executes the uninstall command in the main terminal.
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, false)
