import std/[os, osproc, streams, strutils, tables, times]
import indexes
import ../plugins/[cache, pacman]

const
  RuntimeRefreshLockFile = ".indexes.refresh.lock"
  RuntimeRefreshFlag* = "--internal-refresh-indexes"
  RuntimeRefreshSourcesFlag* = "--refresh-sources"
  RuntimeRefreshLockFlag* = "--refresh-lock"
  RuntimeRefreshMergedOnlyFlag* = "--refresh-merged-only"
  RuntimeIndexDirFlag* = "--index-dir"

proc defaultRuntimeIndexDir*(): string =
  getCachePath() / "indexes"

proc loadInstalledMap(): Table[string, bool] =
  let (output, exitCode) = execCmdEx("pacman -Q")
  if exitCode != 0:
    raise newException(IOError, "failed to collect installed package map")
  parseInstalledPackages(output)

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

proc buildAurIndex(builder: var SourceIndexBuilder, installedMap: Table[string, bool]) =
  var aurCache = initAurCache()
  if not safeLoadOrRefreshCache(aurCache):
    raise newException(IOError, "failed to load AUR cache")

  let binPath = getCachePath() / aurCache.binPath
  var nameBuf = newStringOfCap(256)
  var verBuf = newStringOfCap(64)

  withBinaryCache(binPath, name, version):
    nameBuf.setLen(name.len)
    for i in 0 ..< name.len:
      nameBuf[i] = name[i]

    verBuf.setLen(version.len)
    for i in 0 ..< version.len:
      verBuf[i] = version[i]

    addPackageToIndex(
      builder,
      name = nameBuf,
      version = verBuf,
      repo = "aur",
      installed = installedMap.hasKey(nameBuf),
    )

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

proc buildNimbleIndex(builder: var SourceIndexBuilder, installed: Table[string, bool]) =
  var nimbleCache = initNimbleCache()
  if not safeLoadOrRefreshCache(nimbleCache, keepJson = true):
    raise newException(IOError, "failed to load Nimble cache")

  let binPath = getCachePath() / nimbleCache.binPath
  var nameBuf = newStringOfCap(256)
  var verBuf = newStringOfCap(64)

  withBinaryCache(binPath, name, version):
    nameBuf.setLen(name.len)
    for i in 0 ..< name.len:
      nameBuf[i] = name[i]

    verBuf.setLen(version.len)
    for i in 0 ..< version.len:
      verBuf[i] = version[i]

    addPackageToIndex(
      builder,
      name = nameBuf,
      version = verBuf,
      repo = "nimble",
      installed = installed.hasKey(nameBuf),
    )

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
    buildAurIndex(aurBuilder, installedMap)
    result.add(finishSourceIndex(aurBuilder, outputDir / "aur.prix"))

  if iskNimble in enabledSources:
    var nimbleBuilder = initSourceIndexBuilder(iskNimble)
    buildNimbleIndex(nimbleBuilder, nimbleInstalled)
    result.add(finishSourceIndex(nimbleBuilder, outputDir / "nimble.prix"))

proc buildAllSourceIndexes*(outputDir: string): seq[SourceIndexStats] =
  buildSelectedSourceIndexes(outputDir, {iskSystem, iskAur, iskNimble})

proc indexFilename(source: IndexedSourceKind): string =
  case source
  of iskSystem: "system.prix"
  of iskAur: "aur.prix"
  of iskNimble: "nimble.prix"

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

proc componentIndexPaths(
    outputDir: string, enabledSources: set[IndexedSourceKind]
): seq[string] =
  for source in IndexedSourceKind:
    if source in enabledSources:
      result.add(outputDir / indexFilename(source))

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
      )
  discard finishSourceIndex(builder, path)

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
    let lockTtlSeconds = max(300'i64, int64(CacheMaxAgeHours) * 3600'i64)
    if ageSeconds > lockTtlSeconds:
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
  let args =
    @[
      RuntimeRefreshFlag,
      RuntimeIndexDirFlag & "=" & outputDir,
      RuntimeRefreshSourcesFlag & "=" & encodeEnabledSources(enabledSources),
      RuntimeRefreshLockFlag & "=" & lockPath,
    ] & (if mergedOnly: @[RuntimeRefreshMergedOnlyFlag] else: @[])

  try:
    var procHandle = startProcess(exePath, args = args, options = {poStdErrToStdOut})
    procHandle.close()
  except CatchableError:
    try:
      removeFile(lockPath)
    except CatchableError:
      discard

proc runInternalIndexRefresh*(
    outputDir: string,
    enabledSources: set[IndexedSourceKind],
    lockPath: string = "",
    mergedOnly: bool = false,
): int =
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
  if enabledSources.len == 0:
    return

  var missingOrInvalid = false
  var staleOnly = false
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
      if (getTime() - stampTime).inHours >= CacheMaxAgeHours:
        staleOnly = true

  if missingOrInvalid:
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
