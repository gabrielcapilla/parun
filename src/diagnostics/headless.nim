import std/[json, monotimes, os, strutils, times]
import ../catalog/[model, state]
import ../index/indexes
import ../sources/[index_refresh, package_manager]

const DefaultHeadlessTimeoutMs* = 12_000

type HeadlessDetailRequest* = object
  selector*: string
  indexDir*: string
  timeoutMs*: int

proc detailQualityLabel(quality: DetailQuality): string {.inline.} =
  case quality
  of DetailSummary: "summary"
  of DetailManifest: "manifest"
  of DetailFallback: "fallback"

proc emitError(
    selector, indexDir, errorKind, message: string, elapsedMs: int, exitCode: int
): int =
  let payload = %*{
    "schema_version": 1,
    "kind": "parun_headless_detail",
    "status": "error",
    "selector": selector,
    "index_dir": indexDir,
    "elapsed_ms": elapsedMs,
    "error_kind": errorKind,
    "error": message,
  }
  stdout.write(pretty(payload))
  stdout.write('\n')
  exitCode

proc parseSelector(value: string): tuple[slot: SourceSlot, name: string] =
  let separator = value.find('/')
  if separator <= 0 or separator >= value.high:
    raise newException(ValueError, "selector must use SOURCE/PACKAGE")
  let source = value[0 ..< separator].toLowerAscii()
  let name = value[separator + 1 ..^ 1]
  if name.len == 0:
    raise newException(ValueError, "selector package name is empty")
  let slot =
    case source
    of "local", "system", "pacman":
      SlotSystem
    of "aur":
      SlotAur
    of "nimble", "nim":
      SlotNimble
    else:
      raise newException(ValueError, "unknown selector source: " & source)
  (slot, name)

proc openHeadlessView(state: var AppState, slot: SourceSlot, indexDir: string): string =
  let path = runtimeSourceIndexPath(indexDir, slotToIndexKind(slot))
  let verdict = validateSourceIndex(path, deep = false)
  if not verdict.valid:
    return verdict.error
  try:
    state.sourceViews[slot] = openValidatedSourceIndex(verdict)
  except CatchableError as e:
    return e.msg
  ""

proc findPackage(
    view: ptr SourceIndexView, slot: SourceSlot, name: string
): tuple[index: int32, repo: string, error: string] =
  let repoError = ensureRepoSections(view)
  if repoError.len > 0:
    return (-1'i32, "", repoError)
  for idx in 0 ..< packageCount(view):
    if copyName(view, idx) != name:
      continue
    let repo = copyRepo(view, idx)
    if slot == SlotAur and repo != "aur":
      continue
    if slot == SlotNimble and repo != "nimble":
      continue
    return (int32(idx), repo, "")
  (-1'i32, "", "")

proc runHeadlessDetails*(request: HeadlessDetailRequest): int =
  let started = getMonoTime()
  let indexDir =
    if request.indexDir.len > 0:
      request.indexDir
    else:
      defaultRuntimeIndexDir()
  try:
    let (slot, packageName) = parseSelector(request.selector)
    let source = modeForSlot(slot).source
    var appState = newState(slot, false, {slot}, true)
    defer:
      appState.closeIndexedSources()

    let openError = openHeadlessView(appState, slot, indexDir)
    if openError.len > 0:
      return emitError(
        request.selector,
        indexDir,
        "index_unavailable",
        "index unavailable: " & openError,
        int((getMonoTime() - started).inMilliseconds()),
        1,
      )

    let view = appState.activeView
    let (pkgIdx, repo, packageError) = findPackage(view, slot, packageName)
    if packageError.len > 0:
      return emitError(
        request.selector,
        indexDir,
        "repository_proof",
        "repository proof failed: " & packageError,
        int((getMonoTime() - started).inMilliseconds()),
        1,
      )
    if pkgIdx < 0:
      return emitError(
        request.selector,
        indexDir,
        "missing_package",
        "package not found",
        int((getMonoTime() - started).inMilliseconds()),
        1,
      )

    var summary = ""
    if source == SourceNimble:
      let detailError = ensureDetailSections(view)
      if detailError.len > 0:
        return emitError(
          request.selector,
          indexDir,
          "detail_proof",
          "detail proof failed: " & detailError,
          int((getMonoTime() - started).inMilliseconds()),
          1,
        )
      summary = copyDetail(view, int(pkgIdx))

    var url = ""
    if source == SourceNimble:
      let urlError = ensureUrlSections(view)
      if urlError.len > 0:
        return emitError(
          request.selector,
          indexDir,
          "url_proof",
          "URL proof failed: " & urlError,
          int((getMonoTime() - started).inMilliseconds()),
          1,
        )
      url = copyUrl(view, int(pkgIdx))

    initPackageManagerForSource(source)
    var workerReady = true
    defer:
      if workerReady:
        shutdownPackageManager()

    requestDetails(
      pkgIdx, packageName, repo, url, source, slot, appState.detailGeneration
    )

    var messages = newSeqOfCap[Msg](4)
    let timeoutMs =
      if request.timeoutMs > 0: request.timeoutMs else: DefaultHeadlessTimeoutMs
    while int((getMonoTime() - started).inMilliseconds()) < timeoutMs:
      pollWorkerMessages(messages)
      for msg in messages:
        case msg.kind
        of MsgDetailsLoaded:
          if msg.pkgIdx != pkgIdx or msg.pkgSlot != slot or
              msg.detailGeneration != appState.detailGeneration:
            continue
          let payload = %*{
            "schema_version": 1,
            "kind": "parun_headless_detail",
            "status": "ok",
            "selector": request.selector,
            "index_dir": indexDir,
            "source": $source,
            "repository": repo,
            "package": packageName,
            "package_index": pkgIdx,
            "quality": detailQualityLabel(msg.quality),
            "summary": summary,
            "content": msg.content,
            "elapsed_ms": int((getMonoTime() - started).inMilliseconds()),
          }
          stdout.write(pretty(payload))
          stdout.write('\n')
          return 0
        of MsgError:
          if msg.errorDetailGeneration != appState.detailGeneration or
              msg.errorDetailIdx != pkgIdx or msg.errorDetailSlot != slot:
            continue
          return emitError(
            request.selector,
            indexDir,
            "worker_error",
            msg.errMsg,
            int((getMonoTime() - started).inMilliseconds()),
            1,
          )
        else:
          discard
      sleep(5)

    return emitError(
      request.selector,
      indexDir,
      "timeout",
      "detail request timed out",
      int((getMonoTime() - started).inMilliseconds()),
      1,
    )
  except CatchableError as e:
    emitError(
      request.selector,
      indexDir,
      "internal",
      e.msg,
      int((getMonoTime() - started).inMilliseconds()),
      1,
    )
