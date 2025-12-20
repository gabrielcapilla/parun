import
  std/[
    os, osproc, strutils, strformat, tables, streams, sets, parseutils, parsejson,
    times, monotimes, httpclient, net,
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
    query, pkgId, pkgName, pkgRepo: string
    searchId: int
    source: DataSource

  WorkerRes = Msg

  BatchBuilder = object
    pkgs: seq[PackedPackage]
    textBlock: string
    repos: seq[string]
    repoMap: Table[string, uint8]

  NimbleMeta = tuple[url: string, tags: seq[string]]

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

proc getRawBaseUrl(repoUrl: string): string =
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

proc parseNimbleInfo(raw: string, name, url: string, tags: seq[string]): string =
  var info = initTable[string, string]()
  var requires: seq[string] = @[]

  for line in raw.splitLines():
    let l = line.strip()
    if l.len == 0 or l.startsWith("#"):
      continue

    let lowerL = l.toLowerAscii()

    if lowerL.startsWith("requires"):
      var rest = ""
      if lowerL.startsWith("requires:"):
        rest = l[9 ..^ 1].strip()
      else:
        rest = l[8 ..^ 1].strip()

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

  result = ""
  result.add("Name           : " & name & "\n")
  if info.hasKey("Version"):
    result.add("Version        : " & info["Version"] & "\n")
  if info.hasKey("Author"):
    result.add("Author         : " & info["Author"] & "\n")
  if info.hasKey("Description"):
    result.add("Description    : " & info["Description"] & "\n")
  if info.hasKey("License"):
    result.add("License        : " & info["License"] & "\n")
  result.add("URL            : " & url & "\n")
  if tags.len > 0:
    result.add("Tags           : " & tags.join(", ") & "\n")

  if requires.len > 0:
    result.add("Requires       :" & "\n")
    for r in requires:
      result.add("                 - " & r & "\n")

proc formatFallbackInfo(raw: string): string =
  var info = initTable[string, string]()

  for line in raw.splitLines():
    if line.strip().len == 0:
      continue

    if not line.startsWith(" "):
      if line.endsWith(":"):
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
        else:
          discard

  result = ""
  if info.hasKey("Name"):
    result.add("Name           : " & info["Name"] & "\n")
  if info.hasKey("Version"):
    result.add("Version        : " & info["Version"] & "\n")
  if info.hasKey("Description"):
    result.add("Description    : " & info["Description"] & "\n")
  if info.hasKey("License"):
    result.add("License        : " & info["License"] & "\n")
  if info.hasKey("URL"):
    result.add("URL            : " & info["URL"] & "\n")
  if info.hasKey("Tags"):
    result.add("Tags           : " & info["Tags"] & "\n")
  result.add("\n(Info from local nimble search cache)")

proc workerLoop(tool: string) {.thread.} =
  var currentReq: WorkerReq
  var hasReq = false
  var nimbleMetaCache = initTable[string, NimbleMeta]()
  var client = newHttpClient(timeout = 3000)

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
              if newReq.kind != ReqDetails:
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
        nimbleMetaCache.clear()
        parser.next()

        while parser.kind != jsonEof and parser.kind != jsonError:
          if parser.kind == jsonObjectStart:
            var name = ""
            var url = ""
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
                  while parser.kind != jsonArrayEnd and parser.kind != jsonEof:
                    if parser.kind == jsonString:
                      tags.add(parser.str)
                    parser.next()
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
              if url.len > 0:
                nimbleMetaCache[name] = (url: url, tags: tags)

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
          var content = ""
          var fetched = false
          var meta: NimbleMeta = (url: "", tags: @[])

          if nimbleMetaCache.hasKey(req.pkgName):
            meta = nimbleMetaCache[req.pkgName]
            let rawBase = getRawBaseUrl(meta.url)

            if rawBase.len > 0:
              let branches = ["master", "main"]

              var names = @[req.pkgName]
              if req.pkgName != req.pkgName.toLowerAscii():
                names.add(req.pkgName.toLowerAscii())

              for branch in branches:
                for nameVariant in names:
                  let attemptUrl =
                    rawBase & "/" & branch & "/" & nameVariant & ".nimble"
                  try:
                    let rawContent = client.getContent(attemptUrl)
                    content =
                      parseNimbleInfo(rawContent, req.pkgName, meta.url, meta.tags)
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
            let p = startProcess(
              "nimble", args = ["search", req.pkgName], options = {poUsePath}
            )
            let c = p.outputStream.readAll()
            p.close()
            let formatted = formatFallbackInfo(c)
            resChan.send(
              Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: formatted)
            )
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
