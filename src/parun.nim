## Initializes the terminal, package manager, and main event loop.

import
  std/
    [json, os, posix, terminal, selectors, strutils, parseopt, bitops, monotimes, times]
import ui/[tui, keyboard, terminal as term]
import core/[types, state, engine]
import plugins/manager
import storage/[indexes, index_builder]
import utils/version

const AllSourceKinds = {iskSystem, iskAur, iskNimble}

when defined(linux):
  proc malloc_trim(pad: csize_t): cint {.importc, header: "<malloc.h>".}

proc inferSourceFromRepo(repo: string): DataSource {.inline.} =
  if repo == "nimble": SourceNimble else: SourceSystem

proc printHelp() =
  echo """
Usage: parun [options]

Options:
  -h, --help                 Show this help and exit
  -v, --version              Show version and exit
  -n, --noinfo               Start with details panel hidden
      --perf-out=PATH        Write runtime perf counters JSON on graceful exit
      --pacman               Enable local pacman source
      --aur                  Enable AUR source
      --nimble, --nim        Enable Nimble source

Source Selection:
  - `parun` keeps current behavior: Local is default, and `aur/` or `nim/`
    prefixes switch source on demand.
  - If any of `--pacman`, `--aur`, `--nimble` are passed, they become an
    explicit source filter.
  - In explicit filter mode, unprefixed search shows the combined selected
    sources by default.
  - Default source priority with explicit filters: pacman > aur > nimble.
  - `--pacman` is not implied by `--aur`; use both to enable both.

Examples:
  parun
  parun --nim
  parun --aur --pacman --nimble --noinfo
"""

proc writePerfSnapshot(path: string, state: AppState) =
  if path.len == 0:
    return
  let decode = snapshotColdDecodeStats()
  let dir = parentDir(path)
  if dir.len > 0:
    createDir(dir)
  let payload =
    %*{
      "hot_filter_calls": state.perf.hotFilterCalls,
      "hot_filter_candidates": state.perf.hotFilterCandidates,
      "hot_score_calls": state.perf.hotScoreCalls,
      "hot_installed_checks": state.perf.hotInstalledChecks,
      "hot_bucket_lookups": state.perf.hotBucketLookups,
      "cold_row_renders": state.perf.coldRowRenders,
      "cold_detail_wraps": state.perf.coldDetailWraps,
      "cold_detail_lines": state.perf.coldDetailLines,
      "cold_detail_cache_hits": state.perf.coldDetailCacheHits,
      "cold_detail_cache_misses": state.perf.coldDetailCacheMisses,
      "cold_detail_requests": state.perf.coldDetailRequests,
      "cold_decode_requests": decode.requests,
      "cold_decode_hits": decode.hits,
      "cold_decode_misses": decode.misses,
      "cold_decode_blocks": decode.decodedBlocks,
      "cold_decode_bytes": decode.decodedBytes,
    }
  writeFile(path, pretty(payload))

proc main() =
  var
    startShowDetails = true
    explicitSources = false
    usePacman = false
    useAur = false
    useNimble = false
    runInternalRefresh = false
    internalRefreshMergedOnly = false
    internalIndexDir = ""
    internalRefreshSources = ""
    internalRefreshLock = ""
    perfOutPath = ""

  # CLI Argument Parsing
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "version", "v":
        echo "parun: ", getVersion()
        quit(0)
      of "help", "h":
        printHelp()
        quit(0)
      of "noinfo", "n":
        startShowDetails = false
      of "pacman", "p":
        explicitSources = true
        usePacman = true
      of "aur", "a":
        explicitSources = true
        useAur = true
      of "nimble", "nim", "m":
        explicitSources = true
        useNimble = true
      of RuntimeRefreshFlag.strip(chars = {'-'}):
        runInternalRefresh = true
      of "perf-out":
        perfOutPath = val
      of RuntimeRefreshMergedOnlyFlag.strip(chars = {'-'}):
        internalRefreshMergedOnly = true
      of RuntimeIndexDirFlag.strip(chars = {'-'}):
        internalIndexDir = val
      of RuntimeRefreshSourcesFlag.strip(chars = {'-'}):
        internalRefreshSources = val
      of RuntimeRefreshLockFlag.strip(chars = {'-'}):
        internalRefreshLock = val
      else:
        stderr.writeLine("parun: unknown option -- '", key, "'")
        stderr.writeLine("Try 'parun --help' for more information.")
        quit(1)
    else:
      # Non-option arguments are not supported
      if kind == cmdArgument:
        stderr.writeLine("parun: unexpected argument '", key, "'")
        stderr.writeLine("Try 'parun --help' for more information.")
        quit(1)

  if runInternalRefresh:
    let refreshDir =
      if internalIndexDir.len > 0:
        internalIndexDir
      else:
        defaultRuntimeIndexDir()
    let enabled =
      if internalRefreshSources.len > 0:
        parseEnabledSources(internalRefreshSources)
      else:
        AllSourceKinds
    quit(
      runInternalIndexRefresh(
        refreshDir, enabled, internalRefreshLock, internalRefreshMergedOnly
      )
    )

  var enabledSlots: set[SourceSlot] = {}
  if explicitSources:
    if usePacman:
      enabledSlots.incl(SlotSystem)
    if useAur:
      enabledSlots.incl(SlotAur)
    if useNimble:
      enabledSlots.incl(SlotNimble)
  else:
    enabledSlots = {SlotSystem, SlotAur, SlotNimble}

  if enabledSlots.len == 0:
    stderr.writeLine(
      "parun: no package source selected; use --pacman, --aur, or --nimble."
    )
    stderr.writeLine("Try 'parun --help' for more information.")
    quit(1)

  let initialSlot =
    if SlotSystem in enabledSlots:
      SlotSystem
    elif SlotAur in enabledSlots:
      SlotAur
    else:
      SlotNimble

  var origTerm = initTerminal()
  initPackageManager()

  var appState = newState(
    initialSlot,
    startShowDetails,
    enabledSlots,
    explicitSourceSelection = explicitSources,
  )
  appState.prepareIndexedSources()
  resetColdDecodeStats()
  when defined(linux):
    discard malloc_trim(0)

  # Async I/O Setup
  let selector = newSelector[int]()
  selector.registerHandle(STDIN_FILENO, {Event.Read}, 0)
  selector.registerHandle(resizePipe[0], {Event.Read}, 1)

  defer:
    selector.close()
    closeIndexedSources(appState)
    restoreTerminal(origTerm)
    shutdownPackageManager()

  var renderBuffer = newStringOfCap(8 * 1024)
  var systemTargets = newSeqOfCap[string](8)
  var nimbleTargets = newSeqOfCap[string](8)
  var pendingMsgs = newSeqOfCap[Msg](8)

  # Main Loop
  while not appState.shouldQuit:
    let termH = terminalHeight()
    let termW = terminalWidth()
    let listH = max(1, termH - 2)

    # Install/Uninstall Management
    if appState.shouldInstall or appState.shouldUninstall:
      systemTargets.setLen(0)
      nimbleTargets.setLen(0)
      let selCount = getSelectedCount(appState.selectionBits)
      let totalPkgs = currentPackageCount(appState)
      let view = appState.activeView

      if selCount > 0:
        for i, word in appState.selectionBits:
          if word == 0:
            continue
          for bit in 0 .. 63:
            if testBit(word, bit):
              let realIdx = i * 64 + bit
              if realIdx < totalPkgs:
                let name = copyName(view, realIdx)
                let repo = copyRepo(view, realIdx)
                let source = inferSourceFromRepo(repo)
                if appState.shouldInstall:
                  if source == SourceNimble:
                    nimbleTargets.add(name)
                  else:
                    systemTargets.add(repo & "/" & name)
                else:
                  if source == SourceNimble:
                    nimbleTargets.add(name)
                  else:
                    systemTargets.add(name)
      elif appState.visibleCount() > 0:
        let idx = int(appState.visibleIdxAt(appState.cursor))
        let name = copyName(view, idx)
        let repo = copyRepo(view, idx)
        let source = inferSourceFromRepo(repo)
        if appState.shouldInstall:
          if source == SourceNimble:
            nimbleTargets.add(name)
          else:
            systemTargets.add(repo & "/" & name)
        else:
          if source == SourceNimble:
            nimbleTargets.add(name)
          else:
            systemTargets.add(name)

      if systemTargets.len + nimbleTargets.len > 0:
        restoreTerminal(origTerm)
        var code = 0
        if systemTargets.len > 0:
          code =
            if appState.shouldInstall:
              installPackages(systemTargets, SourceSystem)
            else:
              uninstallPackages(systemTargets, SourceSystem)
        if code == 0 and nimbleTargets.len > 0:
          code =
            if appState.shouldInstall:
              installPackages(nimbleTargets, SourceNimble)
            else:
              uninstallPackages(nimbleTargets, SourceNimble)
        quit(code)
      else:
        appState.shouldInstall = false
        appState.shouldUninstall = false

    # Rendering
    if appState.needsRedraw:
      try:
        let res = renderUi(appState, renderBuffer, termH, termW)
        stdout.write("\e[?25l")
        setCursorPos(0, 0)
        stdout.write(renderBuffer)

        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")

        stdout.flushFile()
        appState.needsRedraw = false
      except IOError:
        # Ignore EAGAIN errors during rapid terminal resize
        # Terminal will redraw on next iteration
        discard

    # Request details only for the stable current selection.
    if appState.showDetails and appState.visibleCount() > 0:
      let view = appState.activeView
      let idx = appState.visibleIdxAt(appState.cursor)
      if not detailCacheHas(appState.detailsCache, idx):
        var shouldRequestNow = false
        if appState.pendingDetailIdx != idx or
            appState.pendingDetailSlot != appState.activeSlot:
          appState.pendingDetailIdx = idx
          appState.pendingDetailSlot = appState.activeSlot
          appState.detailTargetSince = getMonoTime()
          appState.detailRequestInFlight = false
          shouldRequestNow = DetailsRequestDebounceMs <= 0
        elif not appState.detailRequestInFlight and
            (getMonoTime() - appState.detailTargetSince).inMilliseconds() >=
            DetailsRequestDebounceMs and appState.pendingDetailIdx == idx:
          shouldRequestNow = true

        if shouldRequestNow and not appState.detailRequestInFlight:
          let i = int(idx)
          let repo = copyRepo(view, i)
          let source = inferSourceFromRepo(repo)
          requestDetails(idx, copyName(view, i), repo, source, appState.activeSlot)
          appState.detailRequestInFlight = true
          appState.perf.coldDetailRequests.inc()
      else:
        appState.pendingDetailIdx = -1
        appState.detailRequestInFlight = false
    else:
      appState.pendingDetailIdx = -1
      appState.detailRequestInFlight = false

    # Event Waiting (Input or Resize)
    let ready = selector.select(16)
    for key in ready:
      if key.fd == resizePipe[0]:
        # Drain all pending resize events at once (coalescing)
        var b: char
        while posix.read(resizePipe[0], addr b, 1) > 0:
          discard
        appState.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = getKeyAsync()
        if k != '\0':
          var inputMsg = Msg(kind: MsgInput, key: k)
          update(appState, inputMsg, listH)

          if appState.shouldQuit:
            break

    # Worker message processing
    pollWorkerMessages(pendingMsgs)
    for i in 0 ..< pendingMsgs.len:
      update(appState, pendingMsgs[i], listH)

      if appState.shouldQuit:
        break

  writePerfSnapshot(perfOutPath, appState)

when isMainModule:
  main()
