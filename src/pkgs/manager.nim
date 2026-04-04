## Bridge between the UI and the background worker thread.
import std/[os, osproc, strutils]
import ../core/types
import worker_types, worker

const
  ValidPkgNameChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '.', '+', '_', '@'}
  ValidRepoChars = {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.'}
  MaxPkgNameLen = 256

proc isValidPackageName*(name: string): bool =
  ## Validates package name to prevent command injection
  ## Supports format: "name" or "repo/name"
  ## Allowed in name: alphanumeric, hyphen, dot, plus, underscore, at-sign
  if name.len == 0 or name.len > MaxPkgNameLen:
    return false

  # Check for dangerous patterns first
  # These characters could be used for command injection
  if name.contains("..") or name.contains("\\") or name.contains(";") or
      name.contains("|") or name.contains("&") or name.contains("$") or
      name.contains("`") or name.contains("'") or name.contains('"') or
      name.contains("\n") or name.contains("\r") or name.contains("<") or
      name.contains(">") or name.contains("(") or name.contains(")"):
    return false

  # Handle repo/name format
  let slashCount = name.count('/')
  if slashCount > 1:
    return false # Only one / allowed
  elif slashCount == 1:
    # Validate repo/name format
    let parts = name.split('/', 1)
    if parts.len != 2:
      return false
    let repo = parts[0]
    let pkg = parts[1]

    # Validate repo part
    if repo.len == 0 or repo.len > 64:
      return false
    for c in repo:
      if c notin ValidRepoChars:
        return false

    # Validate package name part
    if pkg.len == 0 or pkg.len > MaxPkgNameLen:
      return false
    for c in pkg:
      if c notin ValidPkgNameChars:
        return false
    return true
  else:
    # Simple package name (no repo)
    for c in name:
      if c notin ValidPkgNameChars:
        return false
    return true

var
  ## Thread-safe channels for worker communication
  ## Nim channels are lock-free and thread-safe by design
  reqChan: Channel[WorkerReq]
  resChan: Channel[Msg]
  workerThread: Thread[WorkerThreadArgs]
  activeTool*: PkgManagerType

# Wrapper for thread creation due to closure limitations or parameter count
proc threadEntry(args: WorkerThreadArgs) {.thread.} =
  workerLoop(args.toolType, args.reqChan[], args.resChan[])

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

  createThread(
    workerThread,
    threadEntry,
    WorkerThreadArgs(toolType: activeTool, reqChan: addr reqChan, resChan: addr resChan),
  )

proc shutdownPackageManager*() =
  ## Stops the worker thread and closes channels.
  reqChan.send(WorkerReq(kind: ReqStop))
  # workerThread.join() # Optional but safer
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

proc pollWorkerMessages*(messages: var seq[Msg]) =
  ## Retrieves all pending messages from the worker into a reusable buffer.
  messages.setLen(0)
  while true:
    let (ok, msg) = resChan.tryRecv()
    if not ok:
      break
    messages.add(msg)

func buildCmd*(tool: PkgManagerType, op: string, targets: seq[string]): string =
  let def = getToolDef(tool)
  let prefix = if def.sudo and tool != ManNimble: "sudo " else: ""
  result = prefix & def.bin & op & targets.join(" ")

proc runTransaction*(tool: PkgManagerType, targets: seq[string], install: bool): int =
  if targets.len == 0:
    return 0
  let def = getToolDef(tool)
  let op = if install: def.installCmd else: def.uninstallCmd
  let cmd = buildCmd(tool, op, targets)
  return execCmd(cmd)

proc installPackages*(names: seq[string], source: DataSource): int =
  ## Installs packages with validation to prevent command injection
  for name in names:
    if not isValidPackageName(name):
      stderr.writeLine("Error: Invalid package name: ", name)
      return 1
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, true)

proc uninstallPackages*(names: seq[string], source: DataSource): int =
  ## Uninstalls packages with validation to prevent command injection
  for name in names:
    if not isValidPackageName(name):
      stderr.writeLine("Error: Invalid package name: ", name)
      return 1
  let tool = if source == SourceNimble: ManNimble else: activeTool
  return runTransaction(tool, names, false)
