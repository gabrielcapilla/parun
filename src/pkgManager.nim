import std/[os, osproc, strutils, strformat, tables]
import types, utils

type
  WorkerReqKind = enum
    ReqLoadAll
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

  WorkerRes = Msg

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[WorkerRes]
  workerThread: Thread[string]

proc parseSyncDb(
    lines: string, installedCache: Table[string, string]
): (seq[CompactPackage], string, seq[string]) =
  var
    pkgs = newSeqOfCap[CompactPackage](50000)
    pool = newStringOfCap(2 * 1024 * 1024)
    repos: seq[string] = @[]
    repoMap = initTable[string, uint8]()

  for rawLine in lines.splitLines:
    if rawLine.len == 0:
      continue
    let line = stripAnsi(rawLine)
    if line.len == 0:
      continue

    var i = 0
    let L = line.len

    let rStart = i
    while i < L and line[i] != ' ':
      inc(i)
    if i >= L:
      continue
    let repoName = line[rStart ..< i]
    inc(i)

    let nStart = i
    while i < L and line[i] != ' ':
      inc(i)
    if i >= L:
      continue
    let nameLen = i - nStart
    let nameOffset = int32(pool.len)
    pool.add(line[nStart ..< i])
    inc(i)

    let vStart = i
    while i < L and line[i] != ' ':
      inc(i)
    let verLen = i - vStart
    let verOffset = int32(pool.len)
    pool.add(line[vStart ..< i])

    var isInst = false
    if installedCache.hasKey(line[nStart ..< nStart + nameLen]):
      isInst = true
    elif line.find("[installed]") > 0 or line.find("[instalado]") > 0:
      isInst = true

    if not repoMap.hasKey(repoName):
      repoMap[repoName] = uint8(repos.len)
      repos.add(repoName)

    pkgs.add(
      CompactPackage(
        repoIdx: repoMap[repoName],
        nameOffset: nameOffset,
        nameLen: int16(nameLen),
        verOffset: verOffset,
        verLen: int16(verLen),
        isInstalled: isInst,
      )
    )

  return (pkgs, pool, repos)

proc parseSearchResults(lines: string): (seq[CompactPackage], string, seq[string]) =
  var
    pkgs = newSeqOfCap[CompactPackage](100)
    pool = newStringOfCap(10 * 1024)
    repos: seq[string] = @[]
    repoMap = initTable[string, uint8]()

  for rawLine in lines.splitLines:
    if rawLine.len == 0:
      continue
    if rawLine.startsWith("    "):
      continue

    let line = stripAnsi(rawLine)
    let parts = line.split(' ')
    if parts.len < 2:
      continue

    let repoNameParts = parts[0].split('/')
    if repoNameParts.len < 2:
      continue

    let repoName = repoNameParts[0]
    let name = repoNameParts[1]
    let ver = parts[1]

    let isInst = line.contains("[installed]") or line.contains("[instalado]")

    let nameOffset = int32(pool.len)
    pool.add(name)
    let verOffset = int32(pool.len)
    pool.add(ver)

    if not repoMap.hasKey(repoName):
      repoMap[repoName] = uint8(repos.len)
      repos.add(repoName)

    pkgs.add(
      CompactPackage(
        repoIdx: repoMap[repoName],
        nameOffset: nameOffset,
        nameLen: int16(name.len),
        verOffset: verOffset,
        verLen: int16(ver.len),
        isInstalled: isInst,
      )
    )

  return (pkgs, pool, repos)

proc workerLoop(tool: string) {.thread.} =
  while true:
    let req = reqChan.recv()
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

        let (outp, code) = execCmdEx("pacman -Sl")
        if code == 0:
          let (pkgs, pool, repos) = parseSyncDb(outp, instMap)
          resChan.send(
            Msg(kind: MsgSearchResults, packedPkgs: pkgs, poolData: pool, repos: repos)
          )
        else:
          resChan.send(Msg(kind: MsgError, errMsg: "Failed 'pacman -Sl'."))
      of ReqSearch:
        if tool != "pacman" and req.query.len > 2:
          let cmd = fmt"{tool} -Ss --aur {sanitizeShell(req.query)}"
          let (outp, code) = execCmdEx(cmd)

          if code == 0 and outp.len > 0:
            let (pkgs, pool, repos) = parseSearchResults(outp)
            resChan.send(
              Msg(
                kind: MsgSearchResults,
                packedPkgs: pkgs,
                poolData: pool,
                repos: repos,
                searchId: req.searchId,
              )
            )
      of ReqDetails:
        let target =
          if req.pkgRepo == "local":
            req.pkgName
          else:
            fmt"{req.pkgRepo}/{req.pkgName}"
        let cmd =
          if req.pkgRepo == "local":
            fmt"pacman -Qi {target}"
          else:
            fmt"{tool} -Si {target}"
        let (outp, _) = execCmdEx(cmd)
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

proc requestLoadAll*() =
  reqChan.send(WorkerReq(kind: ReqLoadAll))

proc requestSearch*(query: string, id: int) =
  reqChan.send(WorkerReq(kind: ReqSearch, query: query, searchId: id))

proc requestDetails*(id, name, repo: string) =
  reqChan.send(WorkerReq(kind: ReqDetails, pkgId: id, pkgName: name, pkgRepo: repo))

proc pollWorkerMessages*(): seq[Msg] =
  result = @[]
  while true:
    let (ok, msg) = resChan.tryRecv()
    if not ok:
      break
    result.add(msg)

proc installPackages*(names: seq[string]): int =
  if names.len == 0:
    return 0

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

proc uninstallPackages*(names: seq[string]): int =
  if names.len == 0:
    return 0

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
