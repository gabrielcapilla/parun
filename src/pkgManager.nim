import
  std/[
    os, osproc, strutils, strformat, tables, streams, sets, parseutils, parsejson,
    times, monotimes,
  ]
import types

type
  WorkerReqKind = enum
    ReqLoadAll
    ReqLoadNimble
    ReqSearch
    ReqDetails
    ReqStop

  WorkerReq = object
    kind: WorkerReqKind
    query: string
    pkgId: string
    pkgName: string
    pkgRepo: string
    searchId: int
    source: DataSource

  WorkerRes = Msg

  BatchBuilder = object
    pkgs: seq[PackedPackage]
    textBlock: string
    repos: seq[string]
    repoMap: Table[string, uint8]

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[WorkerRes]
  workerThread: Thread[string]

proc initBatchBuilder(): BatchBuilder =
  result.pkgs = newSeqOfCap[PackedPackage](1000)
  result.textBlock = newStringOfCap(BlockSize)
  result.repos = @[]
  result.repoMap = initTable[string, uint8]()

proc flushBatch(
    bb: var BatchBuilder,
    resChan: var Channel[WorkerRes],
    searchId: int,
    startTime: MonoTime,
) =
  if bb.pkgs.len > 0:
    let dur = (getMonoTime() - startTime).inMilliseconds.int
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        pkgs: bb.pkgs,
        textBlock: bb.textBlock,
        repos: bb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
      )
    )

    bb.pkgs.setLen(0)
    bb.textBlock.setLen(0)

    bb.repos.setLen(0)
    bb.repoMap.clear()

proc addPackage(bb: var BatchBuilder, name, ver, repo: string, installed: bool) =
  if bb.textBlock.len + name.len + ver.len > BlockSize:
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
      rIdx = 0

  let offset = uint16(bb.textBlock.len)
  bb.textBlock.add(name)
  bb.textBlock.add(ver)

  bb.pkgs.add(
    PackedPackage(
      blockIdx: 0,
      offset: offset,
      repoIdx: rIdx,
      nameLen: uint8(name.len),
      verLen: uint8(ver.len),
      flags: if installed: 1 else: 0,
    )
  )

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

proc workerLoop(tool: string) {.thread.} =
  var currentReq: WorkerReq
  var hasReq = false

  while true:
    if not hasReq:
      currentReq = reqChan.recv()
      hasReq = true

    let req = currentReq
    hasReq = false

    try:
      case req.kind
      of ReqStop:
        break
      of ReqLoadAll:
        let tStart = getMonoTime()
        let (instOut, _) = execCmdEx("pacman -Q")
        var instMap = initTable[string, string]()
        for l in instOut.splitLines:
          let parts = l.split(' ')
          if parts.len > 1:
            instMap[parts[0]] = parts[1]

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

          let installed = instMap.hasKey(name) or (line.find("[installed]", i) > 0)

          if bb.textBlock.len + name.len + ver.len > BlockSize or counter >= 1000:
            flushBatch(bb, resChan, req.searchId, tStart)
            counter = 0
            let (hasNew, newReq) = reqChan.tryRecv()
            if hasNew:
              if newReq.kind == ReqDetails:
                discard
              else:
                currentReq = newReq
                hasReq = true
                interrupted = true
                break

          bb.addPackage(name, ver, repo, installed)
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

        let nimbleDir = getHomeDir() / ".nimble"
        let pkgFile = nimbleDir / "packages_official.json"

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
        parser.next()

        while parser.kind != jsonEof and parser.kind != jsonError:
          if parser.kind == jsonObjectStart:
            var name = ""
            parser.next()
            while parser.kind != jsonObjectEnd and parser.kind != jsonEof:
              if parser.kind == jsonString:
                let key = parser.str
                parser.next()
                if key == "name" and parser.kind == jsonString:
                  name = parser.str
                  parser.next()
                else:
                  if parser.kind == jsonObjectStart or parser.kind == jsonArrayStart:
                    skipJsonBlock(parser)
                    parser.next()
                  else:
                    parser.next()
              else:
                parser.next()

            if name.len > 0:
              if bb.textBlock.len + name.len + 10 > BlockSize or counter >= 500:
                flushBatch(bb, resChan, req.searchId, tStart)
                counter = 0
                let (hasNew, newReq) = reqChan.tryRecv()
                if hasNew:
                  if newReq.kind != ReqDetails:
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
        if tool != "pacman" and req.query.len > 2:
          let args = ["-Ss", "--aur", "--color", "never", req.query]
          let p = startProcess(tool, args = args, options = {poUsePath})
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
            let installed = line.contains("[installed]") or line.contains("[instalado]")

            if bb.textBlock.len + name.len + ver.len > BlockSize:
              flushBatch(bb, resChan, req.searchId, tStart)

            bb.addPackage(name, ver, repo, installed)

          flushBatch(bb, resChan, req.searchId, tStart)
      of ReqDetails:
        if req.source == SourceNimble:
          let p = startProcess(
            "nimble", args = ["search", req.pkgName], options = {poUsePath}
          )
          let c = p.outputStream.readAll()
          p.close()
          resChan.send(Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: c))
        else:
          let target =
            if req.pkgRepo == "local":
              req.pkgName
            else:
              fmt"{req.pkgRepo}/{req.pkgName}"
          let bin = if req.pkgRepo == "local": "pacman" else: tool
          let args =
            if req.pkgRepo == "local":
              @["-Qi", target]
            else:
              @["-Si", target]
          let p = startProcess(bin, args = args, options = {poUsePath})
          let c = p.outputStream.readAll()
          p.close()
          resChan.send(Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: c))
    except Exception as e:
      resChan.send(Msg(kind: MsgError, errMsg: e.msg))

proc initPackageManager*() =
  reqChan.open()
  resChan.open()
  let tool =
    if findExe("paru").len > 0:
      "paru"
    elif findExe("yay").len > 0:
      "yay"
    else:
      "pacman"
  createThread(workerThread, workerLoop, tool)

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
    let (ok, msg) = resChan.tryRecv()
    if not ok:
      break
    result.add(msg)

proc installPackages*(names: seq[string], source: DataSource): int =
  if names.len == 0:
    return 0
  if source == SourceNimble:
    return execCmd("nimble install " & names.join(" "))
  else:
    let tool =
      if findExe("paru").len > 0:
        "paru"
      elif findExe("yay").len > 0:
        "yay"
      else:
        "pacman"
    let cmd =
      if tool == "pacman":
        "sudo pacman -S "
      else:
        tool & " -S "
    return execCmd(cmd & names.join(" "))

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  if names.len == 0:
    return 0
  if source == SourceNimble:
    return execCmd("nimble uninstall " & names.join(" "))
  else:
    let tool =
      if findExe("paru").len > 0:
        "paru"
      elif findExe("yay").len > 0:
        "yay"
      else:
        "pacman"
    let cmd =
      if tool == "pacman":
        "sudo pacman -R "
      else:
        tool & " -R "
    return execCmd(cmd & names.join(" "))
