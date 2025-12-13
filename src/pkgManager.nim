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

  PageBuilder* = object
    pages*: seq[string]
    currentPage*: string
    pkgs*: seq[CompactPackage]
    repoMap*: Table[string, uint16]
    repos*: seq[string]

func initPageBuilder*(): PageBuilder =
  result.pages = @[]
  result.currentPage = newStringOfCap(PageSize)
  result.pkgs = newSeqOfCap[CompactPackage](1000)
  result.repoMap = initTable[string, uint16]()
  result.repos = @[]

func addPackageData(
    pb: var PageBuilder, name, ver: string, repoIdx: uint16, flags: uint8
) =
  let needed = name.len + 1 + ver.len + 1

  if pb.currentPage.len + needed > PageSize:
    pb.pages.add(pb.currentPage)
    pb.currentPage = newStringOfCap(PageSize)

  let offset = uint16(pb.currentPage.len)
  let pageIdx = uint16(pb.pages.len)

  pb.currentPage.add(name)
  pb.currentPage.add('\0')
  pb.currentPage.add(ver)
  pb.currentPage.add('\0')

  pb.pkgs.add(
    CompactPackage(
      pageIdx: pageIdx,
      pageOffset: offset,
      repoIdx: repoIdx,
      nameLen: uint8(name.len),
      flags: flags,
    )
  )

proc flushBatch(
    pb: var PageBuilder,
    resChan: var Channel[WorkerRes],
    searchId: int,
    isNimble: bool,
    startTime: MonoTime,
) =
  if pb.currentPage.len > 0:
    pb.pages.add(pb.currentPage)
    pb.currentPage = newStringOfCap(PageSize)

  if pb.pkgs.len > 0:
    let dur = (getMonoTime() - startTime).inMilliseconds.int

    resChan.send(
      Msg(
        kind: MsgSearchResults,
        packedPkgs: pb.pkgs,
        pages: pb.pages,
        repos:
          if isNimble:
            @["nimble"]
          else:
            pb.repos,
        searchId: searchId,
        isAppend: true,
        durationMs: dur,
      )
    )

    pb.pkgs = newSeqOfCap[CompactPackage](1000)
    pb.pages = @[]
    if not isNimble:
      pb.repos = @[]
      pb.repoMap = initTable[string, uint16]()

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[WorkerRes]
  workerThread: Thread[string]

proc parsePacmanOutput*(
    line: string, pb: var PageBuilder, installedMap: Table[string, string]
) =
  var i = 0
  let L = line.len

  let rStart = i
  i += line.skipUntil({' '}, i)
  if i >= L:
    return
  let repoName = line[rStart ..< i]

  i += line.skipWhitespace(i)

  let nStart = i
  i += line.skipUntil({' '}, i)
  let nameLen = i - nStart
  if nameLen <= 0 or nameLen > 255:
    return
  let nameStr = line[nStart ..< i]

  i += line.skipWhitespace(i)

  let vStart = i
  i += line.skipUntil({' '}, i)
  let verStr =
    if i > vStart:
      line[vStart ..< i]
    else:
      "?"

  var flags: uint8 = 0
  if installedMap.hasKey(nameStr):
    flags = 1
  elif line.find("[installed]", i) > 0 or line.find("[instalado]", i) > 0:
    flags = 1

  if not pb.repoMap.hasKey(repoName):
    pb.repoMap[repoName] = uint16(pb.repos.len)
    pb.repos.add(repoName)

  pb.addPackageData(nameStr, verStr, pb.repoMap[repoName], flags)

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

        var pb = initPageBuilder()
        var counter = 0
        var interrupted = false

        while outp.readLine(line):
          if line.len == 0:
            continue
          parsePacmanOutput(line, pb, instMap)

          counter.inc()
          if counter >= 1000:
            pb.flushBatch(resChan, req.searchId, false, tStart)
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

        p.close()
        if not interrupted:
          pb.flushBatch(resChan, req.searchId, false, tStart)
      of ReqLoadNimble:
        let tStart = getMonoTime()
        var installedSet = initHashSet[string]()
        let (listOut, _) = execCmdEx("nimble list -i --noColor")
        for line in listOut.splitLines:
          let parts = line.split(' ')
          if parts.len > 0 and parts[0].len > 0:
            installedSet.incl(parts[0])

        let nimbleDir = getHomeDir() / ".nimble"
        let pkgFile = nimbleDir / "packages_official.json"

        if not fileExists(pkgFile):
          resChan.send(Msg(kind: MsgError, errMsg: "package_official.json not found."))
          continue

        var fs = newFileStream(pkgFile, fmRead)
        if fs == nil:
          resChan.send(
            Msg(kind: MsgError, errMsg: "Cannot open packages_official.json")
          )
          continue

        var p: JsonParser
        open(p, fs, pkgFile)
        defer:
          close(p)

        var pb = initPageBuilder()
        var interrupted = false
        var counter = 0
        p.next()

        while p.kind != jsonEof and p.kind != jsonError:
          counter.inc()
          if counter >= 500:
            pb.flushBatch(resChan, req.searchId, true, tStart)
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

          case p.kind
          of jsonObjectStart:
            var currentName = ""
            p.next()
            while p.kind != jsonObjectEnd and p.kind != jsonEof:
              if p.kind == jsonString:
                let key = p.str
                p.next()
                if key == "name" and p.kind == jsonString:
                  currentName = p.str
                  p.next()
                else:
                  if p.kind == jsonObjectStart or p.kind == jsonArrayStart:
                    skipJsonBlock(p)
                    p.next()
                  else:
                    p.next()
              else:
                p.next()

            if currentName.len > 0 and currentName.len <= 255:
              let flags: uint8 = if currentName in installedSet: 1 else: 0
              pb.addPackageData(currentName, "latest", 0, flags)

            p.next()
          else:
            p.next()

        fs.close()
        if not interrupted:
          pb.flushBatch(resChan, req.searchId, true, tStart)
      of ReqSearch:
        let tStart = getMonoTime()
        if tool != "pacman" and req.query.len > 2:
          let args = ["-Ss", "--aur", "--color", "never", req.query]
          let p = startProcess(tool, args = args, options = {poUsePath})
          var pb = initPageBuilder()
          let outLines = p.outputStream.readAll().splitLines()
          p.close()

          for line in outLines:
            if line.len == 0 or line.startsWith("    "):
              continue
            let parts = line.split(' ')
            if parts.len > 0:
              let fullId = parts[0]
              if '/' in fullId:
                let s = fullId.split('/')
                let repo = s[0]
                let name = s[1]
                let ver =
                  if parts.len > 1:
                    parts[1]
                  else:
                    "?"
                var flags: uint8 = 0
                if line.contains("[installed]") or line.contains("[instalado]"):
                  flags = 1

                if not pb.repoMap.hasKey(repo):
                  pb.repoMap[repo] = uint16(pb.repos.len)
                  pb.repos.add(repo)

                pb.addPackageData(name, ver, pb.repoMap[repo], flags)

          pb.flushBatch(resChan, req.searchId, false, tStart)
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
