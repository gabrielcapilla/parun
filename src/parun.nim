import
  std/[json, os, posix, terminal, selectors, strutils, parseopt, monotimes, times, sets]
import ui/[tui, keyboard, terminal as term]
import catalog/[model, state, search]
import app/[update, version]
import diagnostics/detail_trace
import diagnostics/headless
import sources/package_manager
import sources/index_refresh
import index/[indexes, source_index_validation]

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
  -na, --no-animation        Disable details loading/reveal animation
      --animation=blocks|fade
                              Details animation style (default: blocks)
      --animation-speed=fast|normal|slow|ultraslow
                              Details animation speed (default: fast)
      --perf-out=PATH        Write runtime perf counters JSON on graceful exit
      --headless             Run deterministic non-TUI search diagnostics and exit
      --headless-query=QUERY Query for --headless (repeatable)
      --headless-rounds=N    Rounds for --headless (default: 64)
      --headless-detail=SRC/PKG
                              Resolve one package detail without starting the TUI
      --headless-timeout-ms=N
                              Deadline for --headless-detail (default: 12000)
      --internal-search-replay
                              Run deterministic non-TUI search replay and exit
      --search-query=QUERY   Query for --internal-search-replay (repeatable)
      --search-rounds=N      Rounds for --internal-search-replay (default: 64)
      --internal-validate-index=PATH
                              Validate one .prix file, emit deterministic JSON, exit
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
  let payload = %*{
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

proc checksumResults(
    results: openArray[int32], visibleAll: bool, visibleAllCount: int32
): uint64 =
  result = 1469598103934665603'u64
  let count =
    if visibleAll:
      min(int(visibleAllCount), 4096)
    else:
      min(results.len, 4096)
  for i in 0 ..< count:
    let value =
      if visibleAll:
        uint64(i)
      else:
        uint64(results[i])
    result =
      result xor (value + 0x9E3779B97F4A7C15'u64 + (result shl 6) + (result shr 2))

proc emitSearchError(kind, indexDir, message: string): int =
  if kind == "parun_headless_search":
    let payload = %*{
      "schema_version": 1,
      "kind": kind,
      "status": "error",
      "index_dir": indexDir,
      "error_kind": "search",
      "error": message,
    }
    stdout.write(pretty(payload))
    stdout.write('\n')
  else:
    stderr.writeLine("parun: ", message)
  1

proc runInternalSearchReplay(
    indexDir: string,
    queries: seq[string],
    rounds: int,
    enabledSlots: set[SourceSlot],
    initialSlot: SourceSlot,
    explicitSources: bool,
    outputKind: string = "parun_internal_search_replay",
): int =
  if rounds <= 0:
    return emitSearchError(outputKind, indexDir, "search rounds must be positive")
  var replayQueries = queries
  if replayQueries.len == 0:
    replayQueries = @["a", "lib", "pkg"]

  var appState = newState(
    initialSlot,
    initialShowDetails = false,
    enabledSlots,
    explicitSourceSelection = explicitSources,
  )
  try:
    appState.prepareIndexedSources(indexDir)
  except CatchableError as e:
    return emitSearchError(outputKind, indexDir, e.msg)
  defer:
    closeIndexedSources(appState)

  if not valid(appState.activeView):
    let error =
      if appState.activeView.isNil:
        "search replay index unavailable"
      elif appState.activeView[].proofError.len > 0:
        appState.activeView[].proofError
      else:
        "search replay index unavailable"
    return emitSearchError(outputKind, indexDir, error)

  var
    totalVisible: int64
    totalVisibleAll: int64
    checksum: uint64
    perQuery = newJArray()

  for query in replayQueries:
    var
      queryVisible: int64
      queryChecksum: uint64
      lastVisibleAll = false
      lastVisibleAllCount: int32 = 0
    for round in 0 ..< rounds:
      appState.visibleAll = false
      appState.visibleAllCount = 0
      let filterError = filterIndices(
        query,
        appState.activeView,
        appState.visibleIndices,
        appState.visibleAll,
        appState.visibleAllCount,
        addr appState.perf,
      )
      if filterError.len > 0:
        return emitSearchError(outputKind, indexDir, filterError)
      let count =
        if appState.visibleAll:
          int(appState.visibleAllCount)
        else:
          appState.visibleIndices.len
      queryVisible += count
      totalVisible += count
      if appState.visibleAll:
        totalVisibleAll += int64(appState.visibleAllCount)
      lastVisibleAll = appState.visibleAll
      lastVisibleAllCount = appState.visibleAllCount
      let localChecksum = checksumResults(
        appState.visibleIndices, appState.visibleAll, appState.visibleAllCount
      )
      queryChecksum =
        queryChecksum xor (localChecksum + uint64(round + 1) * 0x9E3779B97F4A7C15'u64)
      checksum =
        checksum xor
        (queryChecksum + localChecksum + uint64(round + 1) * 0xBF58476D1CE4E5B9'u64)

    perQuery.add %*{
      "query": query,
      "rounds": rounds,
      "visible_total": queryVisible,
      "visible_all": lastVisibleAll,
      "visible_all_count": lastVisibleAllCount,
      "checksum": $queryChecksum,
    }

  let payload = %*{
    "schema_version": 1,
    "kind": outputKind,
    "rounds": rounds,
    "query_count": replayQueries.len,
    "package_count": packageCount(appState.activeView),
    "visible_total": totalVisible,
    "visible_all_total": totalVisibleAll,
    "checksum": $checksum,
    "perf": {
      "hot_filter_calls": appState.perf.hotFilterCalls,
      "hot_filter_candidates": appState.perf.hotFilterCandidates,
      "hot_score_calls": appState.perf.hotScoreCalls,
      "hot_installed_checks": appState.perf.hotInstalledChecks,
      "hot_bucket_lookups": appState.perf.hotBucketLookups,
    },
    "queries": perQuery,
  }
  stdout.write(pretty(payload))
  stdout.write('\n')
  0

proc runInternalValidateIndex(path: string): int =
  if path.len == 0:
    stderr.writeLine("parun: --internal-validate-index requires a path")
    return 1
  let verdict = validateSourceIndex(path)
  let payload = %*{
    "schema_version": 1,
    "kind": "parun_internal_validate_index",
    "path": path,
    "valid": verdict.valid,
    "error": verdict.error,
    "package_count": verdict.packageCount,
    "repo_count": verdict.repoCount,
    "section_count": verdict.sectionCount,
    "file_size": verdict.fileSize,
    "source": $verdict.source,
    "format_version": verdict.formatVersion,
    "header_flags": verdict.headerFlags,
  }
  stdout.write(pretty(payload))
  stdout.write('\n')
  if verdict.valid: 0 else: 1

proc main() =
  var
    startShowDetails = true
    explicitSources = false
    usePacman = false
    useAur = false
    useNimble = false
    detailsAnimationEnabled = true
    detailAnimationStyle = DetailAnimationBlocks
    detailAnimationSpeed = DetailAnimationFast
    runInternalRefresh = false
    runInternalSearch = false
    internalValidateIndexPath = ""
    internalRefreshMergedOnly = false
    internalIndexDir = ""
    internalRefreshSources = ""
    internalRefreshLock = ""
    internalSearchQueries: seq[string] = @[]
    internalSearchRounds = 64
    runHeadless = false
    headlessDetailSelector = ""
    headlessTimeoutMs = DefaultHeadlessTimeoutMs
    perfOutPath = ""

  var args = commandLineParams()
  for i in 0 ..< args.len:
    if args[i] == "-na":
      args[i] = "--no-animation"

  var p = initOptParser(args)
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
      of "no-animation", "na":
        detailsAnimationEnabled = false
      of "animation":
        case val
        of "blocks", "block", "scramble":
          detailAnimationStyle = DetailAnimationBlocks
          detailsAnimationEnabled = true
        of "fade":
          detailAnimationStyle = DetailAnimationFade
          detailsAnimationEnabled = true
        else:
          stderr.writeLine(
            "parun: invalid --animation value '", val, "'; use blocks or fade."
          )
          quit(1)
      of "animation-speed":
        case val
        of "fast":
          detailAnimationSpeed = DetailAnimationFast
        of "normal":
          detailAnimationSpeed = DetailAnimationNormal
        of "slow":
          detailAnimationSpeed = DetailAnimationSlow
        of "ultraslow":
          detailAnimationSpeed = DetailAnimationUltraSlow
        else:
          stderr.writeLine(
            "parun: invalid --animation-speed value '", val,
            "'; use fast, normal, slow or ultraslow.",
          )
          quit(1)
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
      of "internal-search-replay":
        runInternalSearch = true
      of "internal-validate-index":
        internalValidateIndexPath = val
      of "search-query":
        if val.len > 0:
          internalSearchQueries.add(val)
      of "search-rounds":
        try:
          internalSearchRounds = parseInt(val)
        except ValueError:
          stderr.writeLine("parun: invalid --search-rounds value '", val, "'")
          quit(1)
      of "perf-out":
        perfOutPath = val
      of "headless":
        runHeadless = true
      of "headless-query", "query":
        if val.len > 0:
          internalSearchQueries.add(val)
      of "headless-rounds", "rounds":
        try:
          internalSearchRounds = parseInt(val)
        except ValueError:
          stderr.writeLine("parun: invalid --headless-rounds value '", val, "'")
          quit(1)
      of "headless-detail":
        headlessDetailSelector = val
      of "headless-timeout-ms":
        try:
          headlessTimeoutMs = parseInt(val)
        except ValueError:
          stderr.writeLine("parun: invalid --headless-timeout-ms value '", val, "'")
          quit(1)
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

  if internalValidateIndexPath.len > 0:
    quit(runInternalValidateIndex(internalValidateIndexPath))

  if headlessDetailSelector.len > 0:
    quit(
      runHeadlessDetails(
        HeadlessDetailRequest(
          selector: headlessDetailSelector,
          indexDir: internalIndexDir,
          timeoutMs: headlessTimeoutMs,
        )
      )
    )

  if runHeadless or runInternalSearch:
    let enabledSlots =
      if explicitSources:
        block:
          var slots: set[SourceSlot] = {}
          if usePacman:
            slots.incl(SlotSystem)
          if useAur:
            slots.incl(SlotAur)
          if useNimble:
            slots.incl(SlotNimble)
          slots
      else:
        {SlotSystem}
    if enabledSlots.len == 0:
      stderr.writeLine("parun: no package source selected for --internal-search-replay")
      quit(1)
    let initialSlot =
      if SlotSystem in enabledSlots:
        SlotSystem
      elif SlotAur in enabledSlots:
        SlotAur
      else:
        SlotNimble
    let replayDir =
      if internalIndexDir.len > 0:
        internalIndexDir
      else:
        defaultRuntimeIndexDir()
    quit(
      runInternalSearchReplay(
        replayDir,
        internalSearchQueries,
        internalSearchRounds,
        enabledSlots,
        initialSlot,
        explicitSources,
        if runHeadless: "parun_headless_search" else: "parun_internal_search_replay",
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
  appState.detailsAnimationEnabled = detailsAnimationEnabled
  appState.detailAnimationStyle = detailAnimationStyle
  appState.detailAnimationSpeed = detailAnimationSpeed
  appState.prepareIndexedSources()
  resetColdDecodeStats()
  when defined(linux):
    discard malloc_trim(0)

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
  var detailTrace = initDetailTrace(getEnv("PARUN_DETAIL_TRACE"))
  detailTrace.traceDetailEvent("startup", appState, renderBuffer, detailIdx = -1)

  while not appState.shouldQuit:
    let termH = terminalHeight()
    let termW = terminalWidth()
    let listH = max(1, termH - 2)
    appState.pollIndexUpdates()

    if appState.shouldInstall or appState.shouldUninstall:
      systemTargets.setLen(0)
      nimbleTargets.setLen(0)
      let selCount = len(appState.selectedPackages)
      let totalPkgs = currentPackageCount(appState)
      let view = appState.activeView

      if selCount > 0:
        for realIdx in 0 ..< totalPkgs:
          if appState.isSelectedPackage(view, realIdx):
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

    if appState.needsRedraw:
      let wrapsBefore = appState.perf.coldDetailWraps
      let scrambleBefore = appState.detailScramble.active
      let renderedDetailIdx =
        if appState.showDetails and appState.visibleCount() > 0:
          appState.visibleIdxAt(appState.cursor)
        else:
          -1'i32
      try:
        let res = renderUi(appState, renderBuffer, termH, termW)
        stdout.write("\e[?25l")
        setCursorPos(0, 0)
        stdout.write(renderBuffer)

        setCursorPos(res.cursorX, res.cursorY)
        stdout.write("\e[?25h")

        stdout.flushFile()
        appState.needsRedraw = false
        detailTrace.traceDetailFirstFrame(appState, renderBuffer)

        if appState.showDetails:
          detailTrace.traceDetailsFrame(appState, renderBuffer, renderedDetailIdx)
          if not detailCacheHas(appState.detailsCache, renderedDetailIdx):
            detailTrace.traceDetailLoadingFrame(appState, renderBuffer)
          if appState.perf.coldDetailWraps > wrapsBefore:
            detailTrace.traceDetailWrappedRender(
              appState, renderBuffer, renderedDetailIdx
            )
          if scrambleBefore and not appState.detailScramble.active:
            detailTrace.traceDetailRevealComplete(
              appState, renderBuffer, renderedDetailIdx
            )
      except IOError:
        discard

    if appState.showDetails and appState.visibleCount() > 0:
      let view = appState.activeView
      let idx = appState.visibleIdxAt(appState.cursor)
      if appState.detailEnrichmentInFlight and (
        appState.detailEnrichmentIdx != idx or
        appState.detailEnrichmentSlot != appState.activeSlot
      ):
        appState.detailEnrichmentInFlight = false
        appState.detailEnrichmentIdx = -1
      if appState.detailScramble.active and (
        appState.detailScramble.pkgIdx != idx or
        appState.detailScramble.pkgSlot != appState.activeSlot
      ):
        appState.detailScramble.active = false
      let hasDetails = detailCacheHas(appState.detailsCache, idx)
      if not hasDetails or appState.detailEnrichmentInFlight:
        var shouldRequestNow = false
        if not appState.detailEnrichmentInFlight:
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
          var requestUrl = ""
          var canRequest = true

          if source == SourceNimble:
            let detailError = ensureDetailSections(view)
            if detailError.len > 0:
              canRequest = false
              appState.statusMessage = "Index validation failed while loading details"
            else:
              let localDetail = copyDetail(view, i)
              if localDetail.len > 0:
                var localMsg = Msg(
                  kind: MsgDetailsLoaded,
                  pkgIdx: idx,
                  pkgSlot: appState.activeSlot,
                  quality: DetailSummary,
                  content: localDetail,
                )
                update(appState, localMsg, listH)
                detailTrace.traceDetailEvent(
                  "details-summary-cached",
                  appState,
                  renderBuffer,
                  payloadBytes = localDetail.len,
                  detailIdx = idx,
                )
                let urlError = ensureUrlSections(view)
                if urlError.len > 0:
                  canRequest = false
                  appState.statusMessage =
                    "Index validation failed while loading details"
                else:
                  requestUrl = copyUrl(view, i)
                  requestDetails(
                    idx,
                    copyName(view, i),
                    repo,
                    requestUrl,
                    source,
                    appState.activeSlot,
                    appState.detailGeneration,
                  )
                  appState.detailEnrichmentInFlight = true
                  appState.detailEnrichmentIdx = idx
                  appState.detailEnrichmentSlot = appState.activeSlot
                  appState.perf.coldDetailRequests.inc()
                  detailTrace.traceDetailEvent(
                    "details-requested", appState, renderBuffer, detailIdx = idx
                  )
                canRequest = false
              else:
                let urlError = ensureUrlSections(view)
                if urlError.len > 0:
                  canRequest = false
                  appState.statusMessage =
                    "Index validation failed while loading details"
                else:
                  requestUrl = copyUrl(view, i)
          if canRequest:
            requestDetails(
              idx,
              copyName(view, i),
              repo,
              requestUrl,
              source,
              appState.activeSlot,
              appState.detailGeneration,
            )
            appState.detailRequestInFlight = true
            appState.perf.coldDetailRequests.inc()
            detailTrace.traceDetailEvent(
              "details-requested", appState, renderBuffer, detailIdx = idx
            )
      else:
        appState.pendingDetailIdx = -1
        appState.detailRequestInFlight = false
    else:
      appState.pendingDetailIdx = -1
      appState.detailRequestInFlight = false
      appState.detailScramble.active = false

    if appState.showDetails and (
      appState.detailRequestInFlight or appState.detailEnrichmentInFlight or
      appState.pendingDetailIdx >= 0 or
      (appState.detailsAnimationEnabled and appState.detailScramble.active)
    ):
      appState.needsRedraw = true

    let ready = selector.select(16)
    for key in ready:
      if key.fd == resizePipe[0]:
        var b: char
        while posix.read(resizePipe[0], addr b, 1) > 0:
          discard
        appState.needsRedraw = true
      elif key.fd == STDIN_FILENO:
        let k = getKeyAsync()
        if k != '\0':
          var inputMsg = Msg(kind: MsgInput, key: k)
          update(appState, inputMsg, listH)

          if inputMsg.key == KeyF1:
            let detailIdx =
              if appState.visibleCount() > 0:
                appState.visibleIdxAt(appState.cursor)
              else:
                -1'i32
            let stage =
              if appState.showDetails:
                if detailIdx >= 0 and detailCacheHas(appState.detailsCache, detailIdx):
                  "details-shown-cache"
                else:
                  "details-shown"
              else:
                "details-hidden"
            detailTrace.traceDetailEvent(
              stage, appState, renderBuffer, detailIdx = detailIdx
            )

          if appState.shouldQuit:
            break

    pollWorkerMessages(pendingMsgs)
    for i in 0 ..< pendingMsgs.len:
      update(appState, pendingMsgs[i], listH)

      case pendingMsgs[i].kind
      of MsgDetailsLoaded:
        let stage =
          case pendingMsgs[i].quality
          of DetailSummary: "details-summary-cached"
          of DetailManifest: "details-cache-updated"
          of DetailFallback: "details-fallback"
        detailTrace.traceDetailEvent(
          stage,
          appState,
          renderBuffer,
          payloadBytes = pendingMsgs[i].content.len,
          detailIdx = pendingMsgs[i].pkgIdx,
        )
      else:
        discard

      if appState.shouldQuit:
        break

  writePerfSnapshot(perfOutPath, appState)

when isMainModule:
  main()
