## Bridge between the UI and the background worker thread.
import std/[os, osproc, strutils]
import ../core/types
import worker_types, worker

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
  workerThread: Thread[
    (
      PkgManagerType,
      ptr Channel[WorkerReq],
      ptr Channel[Msg],
      array[PkgManagerType, ToolDef],
    )
  ]
  activeTool*: PkgManagerType

# Wrapper for thread creation due to closure limitations or parameter count
proc threadEntry(
    args: (
      PkgManagerType,
      ptr Channel[WorkerReq],
      ptr Channel[Msg],
      array[PkgManagerType, ToolDef],
    )
) {.thread.} =
  workerLoop(args[0], args[1][], args[2][], args[3])

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
    workerThread, threadEntry, (activeTool, addr reqChan, addr resChan, Tools)
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

proc pollWorkerMessages*(): seq[Msg] =
  ## Retrieves all pending messages from the worker (non-blocking).
  result = @[]
  while true:
    let (ok, msg) = resChan.tryRecv()
    if not ok:
      break
    result.add(msg)

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
