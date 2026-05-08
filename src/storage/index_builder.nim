## Runtime index orchestration.
##
## Notes:
## - Builds per-source immutable `.prix` indexes from pacman/AUR/Nimble metadata.
## - Applies strict age-based refresh and merged multi-source index generation.
## - Used both at startup and by internal background refresh mode.
## - Current Nimble `.prix` files embed package repository URLs, allowing the
##   details worker to fetch remote `.nimble` manifests without creating
##   `packages.json`/`packages.bin` during side-panel lookup.
import std/[os, osproc, streams, strutils, tables, times]
import indexes
import ../plugins/[cache, pacman]
import ../utils/linux_statx

const
  RuntimeRefreshLockFile = ".indexes.refresh.lock"
  RuntimeRefreshFlag* = "--internal-refresh-indexes"
  RuntimeRefreshSourcesFlag* = "--refresh-sources"
  RuntimeRefreshLockFlag* = "--refresh-lock"
  RuntimeRefreshMergedOnlyFlag* = "--refresh-merged-only"
  RuntimeIndexDirFlag* = "--index-dir"
  RuntimeIndexMaxAgeSecondsEnv* = "PARUN_INDEX_MAX_AGE_SECONDS"

proc defaultRuntimeIndexDir*(): string =
  ## Default runtime index directory under cache root.
  getCachePath()

proc runtimeIndexMaxAgeSeconds(): int64 =
  let defaultSeconds = int64(CacheMaxAgeHours) * 3600'i64
  let raw = getEnv(RuntimeIndexMaxAgeSecondsEnv, "").strip()
  if raw.len == 0:
    return defaultSeconds
  try:
    let parsed = parseInt(raw)
    if parsed <= 0:
      return defaultSeconds
    int64(parsed)
  except ValueError:
    defaultSeconds

proc pathMTimeUnixNs(path: string): int64 =
  when defined(linux):
    let statxTime = statxMTimeUnixNs(path)
    if statxTime.ok:
      return statxTime.ns
  try:
    let fallbackTime = getLastModificationTime(path)
    fallbackTime.toUnix() * 1_000_000_000'i64 + int64(fallbackTime.nanosecond)
  except CatchableError:
    0'i64

proc newestEntryMTimeNs(dirPath: string): int64 =
  ## Returns newest mtime for a directory and its first-level entries.
  ##
  ## Directory mtime can miss metadata rewrites on some filesystems, so
  ## installed-state invalidation scans one level. Linux uses `statx` with a
  ## portable stdlib fallback; missing/unreadable paths return zero and do not
  ## force an index rebuild.
  result = pathMTimeUnixNs(dirPath)
  if result == 0:
    return
  try:
    for kind, path in walkDir(dirPath):
      if kind in {pcFile, pcDir, pcLinkToFile, pcLinkToDir}:
        let mtime = pathMTimeUnixNs(path)
        if mtime > result:
          result = mtime
  except CatchableError:
    discard

proc installedStateMTimeNs(source: IndexedSourceKind): int64 =
  ## Installed flags are embedded in indexes; rebuild when local install DB changed.
  case source
  of iskSystem, iskAur:
    newestEntryMTimeNs("/var/lib/pacman/local")
  of iskNimble:
    let nimbleDir = getHomeDir() / ".nimble"
    let pkgs2 = nimbleDir / "pkgs2"
    let pkgs = nimbleDir / "pkgs"
    max(newestEntryMTimeNs(pkgs2), newestEntryMTimeNs(pkgs))

proc installedStateChangedSince(source: IndexedSourceKind, indexPath: string): bool =
  let stateTime = installedStateMTimeNs(source)
  if stateTime == 0:
    return false
  let indexTime = pathMTimeUnixNs(indexPath)
  indexTime > 0 and stateTime > indexTime

proc shellQuote(value: string): string =
  result = "'"
  for ch in value:
    if ch == '\'':
      result.add("'\\''")
    else:
      result.add(ch)
  result.add("'")

proc safeRemove(path: string) =
  if not fileExists(path):
    return
  try:
    removeFile(path)
  except CatchableError:
    discard

proc tempRefreshPath(outputDir: string, stem, ext: string): string =
  let millis = int64(epochTime() * 1000.0)
  outputDir / ("." & stem & "." & $getCurrentProcessId() & "." & $millis & ext)

proc downloadToPath(url: string, outPath: string): bool =
  execCmd("curl -sfL --max-time 60 " & shellQuote(url) & " > " & shellQuote(outPath)) ==
    0

proc decompressGzipToPath(gzipPath: string, outPath: string): bool =
  execCmd("gunzip -c " & shellQuote(gzipPath) & " > " & shellQuote(outPath)) == 0

proc removeLegacyMetadataArtifacts() =
  let cacheDir = getCachePath()
  for rel in [
    AurBinCache, AurJsonCache, AurJsonGzCache, AurStampFile, NimbleBinCache,
    NimbleJsonCache, NimbleStampFile,
  ]:
    safeRemove(cacheDir / rel)

proc removeLegacyIndexSubdirArtifacts(outputDir: string) =
  let cacheDir = getCachePath()
  if outputDir != cacheDir:
    return
  let legacyDir = cacheDir / "indexes"
  for rel in [
    "system.prix", "aur.prix", "nimble.prix", "merged.system-aur-nimble.prix",
    "merged.system-aur.prix", "merged.system-nimble.prix", "merged.aur-nimble.prix",
    RuntimeRefreshLockFile,
  ]:
    safeRemove(legacyDir / rel)
  if dirExists(legacyDir):
    try:
      removeDir(legacyDir)
    except CatchableError:
      discard

proc streamJsonIntoIndex(
    jsonPath: string,
    repoName: string,
    installed: Table[string, bool],
    builder: var SourceIndexBuilder,
) =
  var nameBuf = newStringOfCap(256)
  var verBuf = newStringOfCap(64)
  var urlBuf = newStringOfCap(128)
  let builderPtr = addr builder
  if not streamParseJsonZeroAlloc(
    jsonPath,
    proc(name: openArray[char], version: openArray[char], url: openArray[char]) =
      nameBuf.setLen(name.len)
      for i in 0 ..< name.len:
        nameBuf[i] = name[i]

      verBuf.setLen(version.len)
      for i in 0 ..< version.len:
        verBuf[i] = version[i]

      urlBuf.setLen(url.len)
      for i in 0 ..< url.len:
        urlBuf[i] = url[i]

      addPackageToIndex(
        builderPtr[],
        name = nameBuf,
        version = verBuf,
        repo = repoName,
        installed = installed.hasKey(nameBuf),
        url = urlBuf,
      ),
  ):
    raise newException(IOError, "failed to parse metadata JSON: " & jsonPath)

proc loadInstalledMap(): Table[string, bool] =
  result = parseInstalledPackagesFromLocalDb()
  if result.len > 0:
    return

  let (output, exitCode) = execCmdEx("pacman -Q")
  if exitCode != 0:
    raise newException(IOError, "failed to collect installed package map")
  result = parseInstalledPackages(output)

proc buildSystemIndex(
    builder: var SourceIndexBuilder, installedMap: Table[string, bool]
) =
  var process = startProcess(
    "pacman",
    args = ["-Sl", "--color", "never"],
    options = {poUsePath, poStdErrToStdOut},
  )
  defer:
    process.close()

  let outp = process.outputStream
  var line = ""

  while outp.readLine(line):
    if line.len == 0:
      continue
    let parts = line.splitWhitespace()
    if parts.len < 3:
      continue
    let name = parts[1]
    addPackageToIndex(
      builder,
      name = name,
      version = parts[2],
      repo = parts[0],
      installed = installedMap.hasKey(name),
    )

proc buildAurIndex(
    builder: var SourceIndexBuilder,
    installedMap: Table[string, bool],
    outputDir: string,
) =
  let tempJsonPath = tempRefreshPath(outputDir, "aur-refresh", ".json.tmp")
  let tempGzPath = tempRefreshPath(outputDir, "aur-refresh", ".json.gz.tmp")
  defer:
    safeRemove(tempJsonPath)
    safeRemove(tempGzPath)

  if not downloadToPath(AurMetaUrl, tempGzPath):
    raise newException(IOError, "failed to download AUR metadata")
  if not decompressGzipToPath(tempGzPath, tempJsonPath):
    raise newException(IOError, "failed to decompress AUR metadata")
  if not validateJsonFile(tempJsonPath):
    raise newException(IOError, "invalid AUR metadata JSON")
  streamJsonIntoIndex(tempJsonPath, "aur", installedMap, builder)

proc loadInstalledNimble(): Table[string, bool] =
  result = initTable[string, bool]()
  let (output, exitCode) = execCmdEx("nimble list -i --noColor")
  if exitCode != 0:
    return
  for line in output.splitLines():
    if line.len == 0:
      continue
    for part in line.splitWhitespace():
      if part.len > 0:
        result[part] = true
        break

proc buildNimbleIndex(
    builder: var SourceIndexBuilder, installed: Table[string, bool], outputDir: string
) =
  let tempJsonPath = tempRefreshPath(outputDir, "nimble-refresh", ".json.tmp")
  defer:
    safeRemove(tempJsonPath)

  if not downloadToPath(NimbleMetaUrl, tempJsonPath):
    raise newException(IOError, "failed to download Nimble metadata")
  if not validateJsonFile(tempJsonPath):
    raise newException(IOError, "invalid Nimble metadata JSON")
  streamJsonIntoIndex(tempJsonPath, "nimble", installed, builder)

proc parseSourceToken(token: string): IndexedSourceKind =
  case token.strip().toLowerAscii()
  of "system", "pacman", "local":
    iskSystem
  of "aur":
    iskAur
  of "nimble", "nim":
    iskNimble
  else:
    raise newException(ValueError, "unknown source token: " & token)

proc parseEnabledSources*(value: string): set[IndexedSourceKind] =
  ## Parses comma-separated source list from CLI/internal flags.
  result = {}
  if value.len == 0:
    return
  for part in value.split(','):
    let token = part.strip()
    if token.len == 0:
      continue
    result.incl(parseSourceToken(token))

proc encodeEnabledSources(enabledSources: set[IndexedSourceKind]): string =
  var parts = newSeqOfCap[string](3)
  for source in IndexedSourceKind:
    if source in enabledSources:
      parts.add(sourceTag(source))
  parts.join(",")

proc buildSelectedSourceIndexes*(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): seq[SourceIndexStats] =
  ## Builds indexes only for selected sources.
  createDir(outputDir)
  var installedMap: Table[string, bool]
  var nimbleInstalled: Table[string, bool]
  let needInstalledMap = iskSystem in enabledSources or iskAur in enabledSources
  if needInstalledMap:
    installedMap = loadInstalledMap()
  if iskNimble in enabledSources:
    nimbleInstalled = loadInstalledNimble()

  if iskSystem in enabledSources:
    var systemBuilder = initSourceIndexBuilder(iskSystem)
    buildSystemIndex(systemBuilder, installedMap)
    result.add(finishSourceIndex(systemBuilder, outputDir / "system.prix"))

  if iskAur in enabledSources:
    var aurBuilder = initSourceIndexBuilder(iskAur)
    buildAurIndex(aurBuilder, installedMap, outputDir)
    result.add(finishSourceIndex(aurBuilder, outputDir / "aur.prix"))

  if iskNimble in enabledSources:
    var nimbleBuilder = initSourceIndexBuilder(iskNimble)
    buildNimbleIndex(nimbleBuilder, nimbleInstalled, outputDir)
    result.add(finishSourceIndex(nimbleBuilder, outputDir / "nimble.prix"))

  removeLegacyMetadataArtifacts()
  removeLegacyIndexSubdirArtifacts(outputDir)

proc buildAllSourceIndexes*(outputDir: string): seq[SourceIndexStats] =
  ## Convenience wrapper for all supported sources.
  buildSelectedSourceIndexes(outputDir, {iskSystem, iskAur, iskNimble})

proc indexFilename(source: IndexedSourceKind): string =
  case source
  of iskSystem: "system.prix"
  of iskAur: "aur.prix"
  of iskNimble: "nimble.prix"

proc runtimeSourceIndexPath*(outputDir: string, source: IndexedSourceKind): string =
  outputDir / indexFilename(source)

proc mergedSourceId(enabledSources: set[IndexedSourceKind]): string =
  var parts = newSeqOfCap[string](3)
  for source in IndexedSourceKind:
    if source in enabledSources:
      parts.add(sourceTag(source))
  if parts.len == 0:
    return "none"
  parts.join("-")

proc mergedIndexPath(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): string =
  outputDir / ("merged." & mergedSourceId(enabledSources) & ".prix")

proc runtimeMergedIndexPath*(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): string =
  mergedIndexPath(outputDir, enabledSources)

proc componentIndexPaths(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): seq[string] =
  for source in IndexedSourceKind:
    if source in enabledSources:
      result.add(runtimeSourceIndexPath(outputDir, source))

proc latestComponentMtime(paths: openArray[string]): Time =
  for path in paths:
    let mtime = getLastModificationTime(path)
    if mtime > result:
      result = mtime

proc buildMergedRuntimeIndex(path: string, sourcePaths: openArray[string]) =
  var builder = initSourceIndexBuilder(iskSystem)
  for sourcePath in sourcePaths:
    var view = openSourceIndex(sourcePath)
    defer:
      view.close()
    let viewPtr = addr view
    let total = packageCount(viewPtr)
    for i in 0 ..< total:
      addPackageToIndex(
        builder,
        name = copyName(viewPtr, i),
        version = copyVersion(viewPtr, i),
        repo = copyRepo(viewPtr, i),
        installed = isInstalled(viewPtr, i),
        url = copyUrl(viewPtr, i),
      )
  discard finishSourceIndex(builder, path)

proc runInternalIndexRefresh*(
  outputDir: string,
  enabledSources: set[IndexedSourceKind],
  lockPath: string = "",
  mergedOnly: bool = false,
): int

proc scheduleStaleRefresh(
  outputDir: string, enabledSources: set[IndexedSourceKind], mergedOnly: bool = false
)

proc rebuildMergedRuntimeIndex(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): string =
  if enabledSources.len == 0:
    raise newException(ValueError, "cannot merge empty source set")
  if enabledSources.len == 1:
    for source in enabledSources:
      return outputDir / indexFilename(source)

  let sourcePaths = componentIndexPaths(outputDir, enabledSources)
  let mergedPath = mergedIndexPath(outputDir, enabledSources)
  buildMergedRuntimeIndex(mergedPath, sourcePaths)
  let refreshed = validateSourceIndex(mergedPath)
  if not refreshed.valid:
    raise newException(
      IOError,
      "failed to prepare merged runtime index: " & mergedPath & " (" & refreshed.error &
        ")",
    )
  mergedPath

proc ensureMergedRuntimeIndex*(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): string =
  ## Returns merged index path, rebuilding only when required.
  if enabledSources.len == 0:
    raise newException(ValueError, "cannot merge empty source set")
  if enabledSources.len == 1:
    for source in enabledSources:
      return outputDir / indexFilename(source)

  let sourcePaths = componentIndexPaths(outputDir, enabledSources)
  let mergedPath = mergedIndexPath(outputDir, enabledSources)
  let mergedValidated = validateSourceIndex(mergedPath)
  let mergedFresh =
    mergedValidated.valid and
    getLastModificationTime(mergedPath) >= latestComponentMtime(sourcePaths)
  if mergedFresh:
    return mergedPath
  if mergedValidated.valid:
    scheduleStaleRefresh(outputDir, enabledSources, mergedOnly = true)
    return mergedPath
  rebuildMergedRuntimeIndex(outputDir, enabledSources)

proc refreshLockPath(outputDir: string): string =
  outputDir / RuntimeRefreshLockFile

proc maybeClearStaleLock(path: string) =
  if not fileExists(path):
    return
  try:
    let ageSeconds = (getTime() - getLastModificationTime(path)).inSeconds()
    if ageSeconds > 300'i64:
      removeFile(path)
  except CatchableError:
    try:
      removeFile(path)
    except CatchableError:
      discard

proc scheduleStaleRefresh(
    outputDir: string, enabledSources: set[IndexedSourceKind], mergedOnly: bool = false
) =
  if enabledSources.len == 0:
    return
  createDir(outputDir)
  let lockPath = refreshLockPath(outputDir)
  maybeClearStaleLock(lockPath)
  if fileExists(lockPath):
    return

  try:
    writeFile(lockPath, $getTime().toUnix())
  except CatchableError:
    return

  let exePath = getAppFilename()
  if exePath.len == 0 or not fileExists(exePath):
    try:
      removeFile(lockPath)
    except CatchableError:
      discard
    return

  let args =
    @[
      RuntimeRefreshFlag,
      RuntimeIndexDirFlag & "=" & outputDir,
      RuntimeRefreshSourcesFlag & "=" & encodeEnabledSources(enabledSources),
      RuntimeRefreshLockFlag & "=" & lockPath,
    ] & (if mergedOnly: @[RuntimeRefreshMergedOnlyFlag] else: @[])

  var launched = false
  try:
    var procHandle = startProcess(exePath, args = args, options = {poStdErrToStdOut})
    let immediateExitCode = peekExitCode(procHandle)
    procHandle.close()
    launched = immediateExitCode == -1 or immediateExitCode == 0
  except CatchableError:
    launched = false

  if not launched:
    try:
      removeFile(lockPath)
    except CatchableError:
      discard

proc scheduleIndexRefresh*(
    outputDir: string, enabledSources: set[IndexedSourceKind], mergedOnly: bool = false
) =
  ## Schedules background index construction; never builds on caller thread.
  scheduleStaleRefresh(outputDir, enabledSources, mergedOnly)

proc prepareRuntimeIndexesAsync*(
    outputDir: string = defaultRuntimeIndexDir(),
    enabledSources: set[IndexedSourceKind] = {iskSystem, iskAur, iskNimble},
): seq[ValidatedSourceIndex] =
  ## Validates existing indexes and schedules stale/missing rebuild work.
  ## Missing indexes are reported as invalid instead of built synchronously.
  if enabledSources.len == 0:
    return
  createDir(outputDir)
  var needsRefresh = false
  let maxAgeSeconds = runtimeIndexMaxAgeSeconds()
  for source in IndexedSourceKind:
    if source notin enabledSources:
      continue
    let path = runtimeSourceIndexPath(outputDir, source)
    let validated = validateSourceIndex(path)
    result.add(validated)
    if not validated.valid:
      needsRefresh = true
      continue
    let stampTime = getLastModificationTime(path)
    if installedStateChangedSince(source, path) or
        (getTime() - stampTime).inSeconds() >= maxAgeSeconds:
      needsRefresh = true
  if needsRefresh:
    scheduleIndexRefresh(outputDir, enabledSources)

proc runInternalIndexRefresh*(
    outputDir: string,
    enabledSources: set[IndexedSourceKind],
    lockPath: string = "",
    mergedOnly: bool = false,
): int =
  ## Entrypoint used by hidden self-spawned refresh mode.
  defer:
    if lockPath.len > 0 and fileExists(lockPath):
      try:
        removeFile(lockPath)
      except CatchableError:
        discard

  if enabledSources.len == 0:
    return 0

  try:
    if mergedOnly:
      discard rebuildMergedRuntimeIndex(outputDir, enabledSources)
      return 0

    discard buildSelectedSourceIndexes(outputDir, enabledSources)
    if enabledSources.len > 1:
      discard rebuildMergedRuntimeIndex(outputDir, enabledSources)
    return 0
  except CatchableError:
    return 1

proc ensureRuntimeIndexes*(
    outputDir: string = defaultRuntimeIndexDir(),
    enabledSources: set[IndexedSourceKind] = {iskSystem, iskAur, iskNimble},
): seq[ValidatedSourceIndex] =
  ## Ensures enabled source indexes exist and are valid.
  ## Missing/invalid indexes are rebuilt synchronously; stale indexes refresh in background.
  if enabledSources.len == 0:
    return

  var missingOrInvalid = false
  var staleOnly = false
  var installedStateChanged = false
  let maxAgeSeconds = runtimeIndexMaxAgeSeconds()
  for source in IndexedSourceKind:
    if source notin enabledSources:
      continue
    let path = outputDir / indexFilename(source)
    let validated = validateSourceIndex(path)
    result.add(validated)
    if not validated.valid:
      missingOrInvalid = true
    else:
      let stampTime = getLastModificationTime(path)
      if installedStateChangedSince(source, path):
        installedStateChanged = true
      if (getTime() - stampTime).inSeconds() >= maxAgeSeconds:
        staleOnly = true

  if missingOrInvalid or installedStateChanged:
    discard buildSelectedSourceIndexes(outputDir, enabledSources)

    result.setLen(0)
    for source in IndexedSourceKind:
      if source notin enabledSources:
        continue
      let path = outputDir / indexFilename(source)
      let validated = validateSourceIndex(path)
      if not validated.valid:
        raise newException(
          IOError,
          "failed to prepare runtime index: " & path & " (" & validated.error & ")",
        )
      result.add(validated)
  elif staleOnly:
    scheduleStaleRefresh(outputDir, enabledSources)
