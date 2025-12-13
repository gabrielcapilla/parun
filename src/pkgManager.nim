import
  std/[os, osproc, strutils, strformat, tables, streams, sets, parseutils, parsejson]
import types, utils

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

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[WorkerRes]
  workerThread: Thread[string]

proc parseSingleLine(
    line: string,
    pool: var string,
    repoMap: var Table[string, uint16],
    repos: var seq[string],
    installedMap: Table[string, string],
): CompactPackage =
  var i = 0
  let L = line.len

  let rStart = i
  i += line.skipUntil({' '}, i)
  if i >= L:
    return
  let repoName = line[rStart ..< i]

  i += line.skipWhitespace(i)
  if i >= L:
    return

  let nStart = i
  i += line.skipUntil({' '}, i)
  let nameLen = i - nStart
  if nameLen <= 0 or nameLen > 255:
    return

  let nameStr = line[nStart ..< i]

  let offset = int32(pool.len)
  pool.add(nameStr)
  pool.add('\0')

  i += line.skipWhitespace(i)

  let vStart = i
  i += line.skipUntil({' '}, i)
  if i > vStart:
    pool.add(line[vStart ..< i])
  else:
    pool.add("?")
  pool.add('\0')

  var flags: uint8 = 0
  if installedMap.hasKey(nameStr):
    flags = 1
  elif i < L and (line.find("[installed]", i) > 0 or line.find("[instalado]", i) > 0):
    flags = 1

  if not repoMap.hasKey(repoName):
    repoMap[repoName] = uint16(repos.len)
    repos.add(repoName)

  result = CompactPackage(
    offset: offset, repoIdx: repoMap[repoName], nameLen: uint8(nameLen), flags: flags
  )

proc parseSearchResults(lines: string): (seq[CompactPackage], string, seq[string]) =
  var pkgs = newSeqOfCap[CompactPackage](100)
  var pool = newStringOfCap(4096)
  var repos: seq[string] = @[]
  var repoMap = initTable[string, uint16]()

  for rawLine in lines.splitLines:
    if rawLine.len == 0:
      continue
    if rawLine.startsWith("    "):
      continue

    let line = stripAnsi(rawLine)

    var i = 0
    let slashPos = line.find('/')
    if slashPos == -1:
      continue

    let repoName = line[0 ..< slashPos]
    i = slashPos + 1

    let spacePos = line.find(' ', i)
    if spacePos == -1:
      continue

    let name = line[i ..< spacePos]
    if name.len > 255:
      continue
    i = spacePos + 1

    while i < line.len and line[i] == ' ':
      inc(i)
    if i >= line.len:
      continue

    let vEnd = line.find(' ', i)
    let ver =
      if vEnd == -1:
        line[i .. ^1]
      else:
        line[i ..< vEnd]

    let isInst = line.contains("[installed]") or line.contains("[instalado]")
    let flags: uint8 = if isInst: 1 else: 0

    let offset = int32(pool.len)
    pool.add(name)
    pool.add('\0')
    pool.add(ver)
    pool.add('\0')

    if not repoMap.hasKey(repoName):
      repoMap[repoName] = uint16(repos.len)
      repos.add(repoName)

    pkgs.add(
      CompactPackage(
        offset: offset,
        repoIdx: repoMap[repoName],
        nameLen: uint8(name.len),
        flags: flags,
      )
    )
  return (pkgs, pool, repos)

proc sendBatch(
    resChan: var Channel[WorkerRes],
    pkgs: var seq[CompactPackage],
    pool: var string,
    repos: var seq[string],
    repoMap: var Table[string, uint16],
    searchId: int,
    isNimble: bool = false,
) =
  if pkgs.len > 0:
    resChan.send(
      Msg(
        kind: MsgSearchResults,
        packedPkgs: pkgs,
        poolData: pool,
        repos:
          if isNimble:
            @["nimble"]
          else:
            repos,
        searchId: searchId,
        isAppend: true,
      )
    )
    pkgs = newSeqOfCap[CompactPackage](2000)
    pool = newStringOfCap(64 * 1024)
    if not isNimble:
      repos = @[]
      repoMap = initTable[string, uint16]()

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

        var batchPkgs = newSeqOfCap[CompactPackage](2000)
        var batchPool = newStringOfCap(64 * 1024)
        var batchRepos: seq[string] = @[]
        var batchRepoMap = initTable[string, uint16]()

        var interrupted = false
        var counter = 0

        while outp.readLine(line):
          counter.inc()
          if counter mod 500 == 0:
            let (hasNew, newReq) = reqChan.tryRecv()
            if hasNew:
              if newReq.kind == ReqDetails:
                discard
              else:
                currentReq = newReq
                hasReq = true
                interrupted = true
                break

          if line.len == 0:
            continue

          let pkg = parseSingleLine(line, batchPool, batchRepoMap, batchRepos, instMap)
          if pkg.nameLen > 0:
            batchPkgs.add(pkg)

          if batchPkgs.len >= 2000:
            sendBatch(
              resChan, batchPkgs, batchPool, batchRepos, batchRepoMap, req.searchId,
              false,
            )

        p.close()

        if interrupted:
          continue

        if batchPkgs.len > 0:
          sendBatch(
            resChan, batchPkgs, batchPool, batchRepos, batchRepoMap, req.searchId, false
          )
      of ReqLoadNimble:
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

        var batchPkgs = newSeqOfCap[CompactPackage](200)
        var batchPool = newStringOfCap(8192)
        var interrupted = false
        var counter = 0

        var dummyRepos: seq[string] = @[]
        var dummyMap: Table[string, uint16]

        p.next()

        while p.kind != jsonEof and p.kind != jsonError:
          counter.inc()
          if counter mod 100 == 0:
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
              let offset = int32(batchPool.len)
              batchPool.add(currentName)
              batchPool.add('\0')
              batchPool.add("latest")
              batchPool.add('\0')

              let flags: uint8 = if currentName in installedSet: 1 else: 0
              batchPkgs.add(
                CompactPackage(
                  offset: offset,
                  repoIdx: 0,
                  nameLen: uint8(currentName.len),
                  flags: flags,
                )
              )

              if batchPkgs.len >= 200:
                sendBatch(
                  resChan, batchPkgs, batchPool, dummyRepos, dummyMap, req.searchId,
                  true,
                )

            p.next()
          else:
            p.next()

        fs.close()

        if interrupted:
          continue

        if batchPkgs.len > 0:
          sendBatch(
            resChan, batchPkgs, batchPool, dummyRepos, dummyMap, req.searchId, true
          )
      of ReqSearch:
        if tool != "pacman" and req.query.len > 2:
          let args = ["-Ss", "--aur", "--color", "never", req.query]
          let p = startProcess(tool, args = args, options = {poUsePath})
          let outp = p.outputStream.readAll()
          p.close()

          let (sPkgs, sPool, sRepos) = parseSearchResults(outp)

          resChan.send(
            Msg(
              kind: MsgSearchResults,
              packedPkgs: sPkgs,
              poolData: sPool,
              repos: sRepos,
              searchId: req.searchId,
              isAppend: true,
            )
          )
      of ReqDetails:
        if req.source == SourceNimble:
          let p = startProcess(
            "nimble", args = ["search", req.pkgName], options = {poUsePath}
          )
          let outp = p.outputStream.readAll()
          p.close()
          resChan.send(Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: outp))
        else:
          let target =
            if req.pkgRepo == "local":
              req.pkgName
            else:
              fmt"{req.pkgRepo}/{req.pkgName}"

          let args =
            if req.pkgRepo == "local":
              @["-Qi", target]
            else:
              @["-Si", target]
          let bin = if req.pkgRepo == "local": "pacman" else: tool

          let p = startProcess(bin, args = args, options = {poUsePath})
          let outp = p.outputStream.readAll()
          p.close()

          resChan.send(Msg(kind: MsgDetailsLoaded, pkgId: req.pkgId, content: outp))
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
    var cleanNames: seq[string] = @[]
    for n in names:
      if n.contains('/'):
        cleanNames.add(n.split('/')[1])
      else:
        cleanNames.add(n)

    stdout.write("\n")
    stdout.write(fmt"{AnsiBold}Nimble Packages ({cleanNames.len}){AnsiReset}")
    stdout.write("\n\n")

    for n in cleanNames:
      stdout.write(fmt"  {ColorPkg}{n}{AnsiReset} (latest)\n")

    stdout.write("\n")
    stdout.write(fmt"{AnsiBold}:: Continue with the installation? [Y/n] {AnsiReset}")
    stdout.flushFile()

    let answer = stdin.readLine().toLowerAscii()
    if answer == "" or answer == "s" or answer == "y":
      return execCmd("nimble install " & cleanNames.join(" "))
    else:
      stdout.write("Operation cancelled.\n")
      return 1
  else:
    let tool =
      if findExe("paru").len > 0:
        "paru"
      elif findExe("yay").len > 0:
        "yay"
      else:
        "pacman"

    var cmd = ""
    if tool == "pacman":
      cmd = "sudo pacman -S "
    else:
      cmd = tool & " -S "

    return execCmd(cmd & names.join(" "))

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  if names.len == 0:
    return 0

  if source == SourceNimble:
    var cleanNames: seq[string] = @[]
    for n in names:
      if n.contains('/'):
        cleanNames.add(n.split('/')[1])
      else:
        cleanNames.add(n)

    stdout.write("\n")
    stdout.write(fmt"{AnsiBold}Nimble Packages to DELETE ({cleanNames.len}){AnsiReset}")
    stdout.write("\n\n")

    for n in cleanNames:
      stdout.write(fmt"  {ColorPkg}{n}{AnsiReset}\n")

    stdout.write("\n")
    stdout.write(fmt"{AnsiBold}:: Continue with uninstalling? [Y/n] {AnsiReset}")
    stdout.flushFile()

    let answer = stdin.readLine().toLowerAscii()
    if answer == "" or answer == "s" or answer == "y":
      return execCmd("nimble uninstall " & cleanNames.join(" "))
    else:
      stdout.write("Operation cancelled.\n")
      return 1
  else:
    let tool =
      if findExe("paru").len > 0:
        "paru"
      elif findExe("yay").len > 0:
        "yay"
      else:
        "pacman"
    var cmd = ""
    if tool == "pacman":
      cmd = "sudo pacman -R "
    else:
      cmd = tool & " -R "
    return execCmd(cmd & names.join(" "))
