import std/[osproc, posix, strutils]
import ../catalog/model
import worker_protocol, worker
import source_registry
import source_contracts

const
  ValidPkgNameChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '+', '_', '@'}
  ValidRepoChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}
  MaxPkgNameLen = 256

type TransactionCommand* = object
  exe*: string
  args*: seq[string]

when defined(linux):
  const
    SysPidfdOpen = 434.clong
    PollIn = 0x001.cshort

  type PollFd {.importc: "struct pollfd", header: "<poll.h>".} = object
    fd: cint
    events: cshort
    revents: cshort

  proc syscall(number: clong): clong {.importc, header: "<unistd.h>", varargs.}

  proc poll(
    fds: ptr PollFd, nfds: culong, timeout: cint
  ): cint {.importc, header: "<poll.h>".}

  proc pidfdOpen(pid: cint): cint {.inline.} =
    cint(syscall(SysPidfdOpen, pid, 0.cuint))

  proc waitPidfdReadable(pidfd: cint) =
    if pidfd < 0:
      return
    var fd = PollFd(fd: pidfd, events: PollIn, revents: 0)
    while true:
      let ready = poll(addr fd, 1.culong, -1)
      if ready > 0:
        break
      if ready < 0 and errno == EINTR:
        continue
      break

else:
  proc pidfdOpen(pid: cint): cint {.inline.} =
    -1

  proc waitPidfdReadable(pidfd: cint) {.inline.} =
    discard

proc isValidPackageName*(name: string): bool =
  if name.len == 0 or name.len > MaxPkgNameLen:
    return false

  var hasSeparator = false
  var repoAllowed = true
  var previousDot = false
  for i, c in name:
    if c == '/':
      if hasSeparator or i == 0 or i == name.high or i > 64 or not repoAllowed:
        return false
      hasSeparator = true
      previousDot = false
      continue
    if c notin ValidPkgNameChars or (c == '.' and previousDot):
      return false
    previousDot = c == '.'
    if not hasSeparator and c notin ValidRepoChars:
      repoAllowed = false
  true

var
  reqChan: Channel[WorkerReq]
  resChan: Channel[Msg]
  workerThread: Thread[WorkerThreadArgs]
  activeTool*: PkgManagerType
  dispatchInstalled: bool
  workerRunning: bool

proc threadEntry(args: WorkerThreadArgs) {.thread.} =
  workerLoop(args.toolType, args.reqChan[], args.resChan[])

proc ensureWorkerRunning() =
  if workerRunning:
    return
  reqChan.open()
  resChan.open()
  createThread(
    workerThread,
    threadEntry,
    WorkerThreadArgs(toolType: activeTool, reqChan: addr reqChan, resChan: addr resChan),
  )
  workerRunning = true

proc enqueueDetails(
    idx: int32,
    name, repo, url: string,
    source: DataSource,
    slot: SourceSlot,
    detailGeneration: uint64,
) {.gcsafe.} =
  ensureWorkerRunning()
  reqChan.send(
    WorkerReq(
      kind: ReqDetails,
      pkgIdx: idx,
      detailGeneration: detailGeneration,
      pkgName: name,
      pkgRepo: repo,
      pkgUrl: url,
      source: source,
      pkgSlot: slot,
    )
  )

proc requestWorkerDiagnostics*() =
  ensureWorkerRunning()
  reqChan.send(WorkerReq(kind: ReqDiagnostics))

proc initPackageManager*() =
  if not dispatchInstalled:
    installRequestDetailsDispatch(enqueueDetails)
    dispatchInstalled = true

  activeTool = detectSystemPlugin()
  let activeDef = getToolDef(activeTool)
  if activeDef.source != SourceSystem:
    raise newException(
      ValueError, "detected active system plugin has invalid source: " & activeDef.key
    )
  enforceCapabilities(
    activeDef,
    {capSearch, capInstall, capUninstall, capDetails, capSystemCatalog, capAurCatalog},
    "system plugin init",
  )

proc initPackageManagerForSource*(source: DataSource) =
  if not dispatchInstalled:
    installRequestDetailsDispatch(enqueueDetails)
    dispatchInstalled = true

  activeTool =
    if source == SourceNimble:
      PluginNimble
    else:
      detectSystemPlugin()
  let activeDef = getToolDef(activeTool)
  case source
  of SourceNimble:
    enforceCapabilities(
      activeDef, {capSearch, capDetails, capNimbleCatalog}, "headless Nimble init"
    )
  of SourceSystem:
    enforceCapabilities(
      activeDef,
      {capSearch, capDetails, capSystemCatalog, capAurCatalog},
      "headless system init",
    )

proc shutdownPackageManager*() =
  if not workerRunning:
    return
  reqChan.send(WorkerReq(kind: ReqStop))
  joinThread(workerThread)
  reqChan.close()
  resChan.close()
  workerRunning = false

proc pollWorkerMessages*(messages: var seq[Msg]) =
  messages.setLen(0)
  if not workerRunning:
    return
  while true:
    let (ok, msg) = resChan.tryRecv()
    if not ok:
      break
    messages.add(msg)

func buildTransactionCommand*(
    tool: PkgManagerType, op: string, targets: seq[string]
): TransactionCommand =
  let def = getToolDef(tool)
  let opParts = op.splitWhitespace()
  if def.sudo:
    result.exe = "sudo"
    result.args = @[def.bin] & opParts & targets
  else:
    result.exe = def.bin
    result.args = opParts & targets

proc runTransaction*(tool: PkgManagerType, targets: seq[string], install: bool): int =
  if targets.len == 0:
    return 0
  let def = getToolDef(tool)
  if install:
    enforceCapabilities(def, {capInstall}, "install transaction")
  else:
    enforceCapabilities(def, {capUninstall}, "uninstall transaction")
  let op = if install: def.installCmd else: def.uninstallCmd
  let cmd = buildTransactionCommand(tool, op, targets)
  var process =
    startProcess(cmd.exe, args = cmd.args, options = {poUsePath, poParentStreams})
  let pidfd = pidfdOpen(cint(process.processID))
  if pidfd >= 0:
    waitPidfdReadable(pidfd)
    discard close(pidfd)
  result = waitForExit(process)
  close(process)

proc installPackages*(names: seq[string], source: DataSource): int =
  for name in names:
    if not isValidPackageName(name):
      stderr.writeLine("Error: Invalid package name: ", name)
      return 1
  let tool = pluginForSource(source, activeTool)
  return runTransaction(tool, names, true)

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  for name in names:
    if not isValidPackageName(name):
      stderr.writeLine("Error: Invalid package name: ", name)
      return 1
  let tool = pluginForSource(source, activeTool)
  return runTransaction(tool, names, false)
