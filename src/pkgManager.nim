import
  std/[
    os, osproc, strutils, strformat, tables, streams, sets, parsejson, monotimes,
    httpclient, net, parseutils,
  ]
import types, batcher, nUtils, pUtils

type
  WorkerReqKind = enum
    ReqLoadAll
    ReqLoadNimble
    ReqSearch
    ReqDetails
    ReqStop

  WorkerReq = object
    kind: WorkerReqKind
    query, pkgId, pkgName, pkgRepo: string
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

const Tools*: array[PkgManagerType, ToolDef] = [
  ManPacman: ToolDef(
    bin: "pacman",
    installCmd: " -S ",
    uninstallCmd: " -R ",
    searchCmd: " -Ss ",
    sudo: true,
    supportsAur: false,
  ),
  ManParu: ToolDef(
    bin: "paru",
    installCmd: " -S ",
    uninstallCmd: " -R ",
    searchCmd: " -Ss ",
    sudo: false,
    supportsAur: true,
  ),
  ManYay: ToolDef(
    bin: "yay",
    installCmd: " -S ",
    uninstallCmd: " -R ",
    searchCmd: " -Ss ",
    sudo: false,
    supportsAur: true,
  ),
  ManNimble: ToolDef(
    bin: "nimble",
    installCmd: " install ",
    uninstallCmd: " uninstall ",
    searchCmd: " search ",
    sudo: false,
    supportsAur: false,
  ),
]

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[Msg]
  workerThread: Thread[PkgManagerType]
  activeTool*: PkgManagerType

proc skipJsonBlock(p: var JsonParser) =
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

          if bb.textBlock.len + name.len + ver.len > BlockSize or counter >= 1000:
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
        let tStart = getMonoTime()
        var installedSet = initHashSet[string]()
        let (listOut, _) = execCmdEx("nimble list -i --noColor")
        for line in listOut.splitLines:
          let parts = line.split(' ')
          if parts.len > 0:
            installedSet.incl(parts[0])

        let pkgFile = getHomeDir() / ".nimble/packages_official.json"
        if not fileExists(pkgFile):
          resChan.send(Msg(kind: MsgError, errMsg: "package_official.json missing"))
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
            var name, url = ""
            var tags: seq[string] = @[]
            parser.next()
            while parser.kind != jsonObjectEnd and parser.kind != jsonEof:
              if parser.kind == jsonString:
                let key = parser.str
                parser.next()
                if key == "name" and parser.kind == jsonString:
                  name = parser.str
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
              if url.len > 0:
                nimbleMetaCache[name] = (url: url, tags: tags)
              if bb.textBlock.len + name.len + 10 > BlockSize or counter >= 500:
                flushBatch(bb, resChan, req.searchId, tStart)
                counter = 0
                let (hasNew, newReq) = reqChan.tryRecv()
                if hasNew and newReq.kind != ReqDetails:
                  currentReq = newReq
                  hasReq = true
                  interrupted = true
                  break
              bb.addPackage(name, "latest", "nimble", name in installedSet)
              counter.inc()
            parser.next()
          else:
            parser.next()
        fs.close()
        if not interrupted:
          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqSearch:
        let tStart = getMonoTime()
        if toolDef.supportsAur and req.query.len > 2:
          let p = startProcess(
            toolDef.bin,
            args = ["-Ss", "--aur", "--color", "never", req.query],
            options = {poUsePath},
          )
          let outLines = p.outputStream.readAll().splitLines()
          p.close()
          var bb = initBatchBuilder()
          for line in outLines:
            if line.len == 0 or line.startsWith("    "):
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
            if bb.textBlock.len + name.len + ver.len > BlockSize:
              flushBatch(bb, resChan, req.searchId, tStart)
            bb.addPackage(
              name,
              ver,
              repo,
              line.contains("[installed]") or line.contains("[instalado]"),
            )
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
              Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: content)
            )
          else:
            let (c, _) = execCmdEx("nimble search " & req.pkgName)
            resChan.send(
              Msg(
                kind: MsgDetailsLoaded, pkgId: req.pkgId, content: formatFallbackInfo(c)
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
          resChan.send(Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: c))
    except Exception as e:
      resChan.send(Msg(kind: MsgError, errMsg: e.msg))

proc initPackageManager*() =
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
  reqChan.send(WorkerReq(kind: ReqStop))
  joinThread(workerThread)
  reqChan.close()
  resChan.close()

proc requestLoadAll*(id: int) =
  reqChan.send(WorkerReq(kind: ReqLoadAll, searchId: id))

proc requestLoadNimble*(id: int) =
  reqChan.send(WorkerReq(kind: ReqLoadNimble, searchId: id))

proc requestSearch*(query: string, id: int) =
  reqChan.send(WorkerReq(kind: ReqSearch, query: query, searchId: id))

proc requestDetails*(id, name, repo: string, source: DataSource) =
  reqChan.send(
    WorkerReq(kind: ReqDetails, pkgId: id, pkgName: name, pkgRepo: repo, source: source)
  )

proc pollWorkerMessages*(): seq[Msg] =
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
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, true)

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, false)
