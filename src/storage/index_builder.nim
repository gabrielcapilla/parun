import std/[os, osproc, streams, strutils, tables]
import indexes
import ../pkgs/cache
import ../pkgs/backends/pacman

proc defaultRuntimeIndexDir*(): string =
  getCachePath() / "indexes"

proc copyChars(chars: openArray[char]): string =
  result = newString(chars.len)
  for i in 0 ..< chars.len:
    result[i] = chars[i]

proc loadInstalledMap(): Table[string, string] =
  let (output, exitCode) = execCmdEx("pacman -Q")
  if exitCode != 0:
    raise newException(IOError, "failed to collect installed package map")
  parseInstalledPackages(output)

proc collectSystemPackages(installedMap: Table[string, string]): seq[IndexedPackageRecord] =
  var process = startProcess(
    "pacman",
    args = ["-Sl", "--color", "never"],
    options = {poUsePath, poStdErrToStdOut},
  )
  defer:
    process.close()

  let outp = process.outputStream
  var line = ""
  result = newSeqOfCap[IndexedPackageRecord](24000)

  while outp.readLine(line):
    if line.len == 0:
      continue
    let parts = line.splitWhitespace()
    if parts.len < 3:
      continue
    let name = parts[1]
    result.add(
      IndexedPackageRecord(
        name: name,
        version: parts[2],
        repo: parts[0],
        installed: installedMap.hasKey(name),
      )
    )

proc collectAurPackages(installedMap: Table[string, string]): seq[IndexedPackageRecord] =
  var aurCache = initAurCache()
  if not safeLoadOrRefreshCache(aurCache):
    raise newException(IOError, "failed to load AUR cache")

  let binPath = getCachePath() / aurCache.binPath
  result = newSeqOfCap[IndexedPackageRecord](120000)
  var nameBuf = newStringOfCap(256)

  withBinaryCache(binPath, name, version):
    nameBuf.setLen(name.len)
    for i in 0 ..< name.len:
      nameBuf[i] = name[i]
    result.add(
      IndexedPackageRecord(
        name: nameBuf,
        version: copyChars(version),
        repo: "aur",
        installed: installedMap.hasKey(nameBuf),
      )
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

proc collectNimblePackages(installed: Table[string, bool]): seq[IndexedPackageRecord] =
  var nimbleCache = initNimbleCache()
  if not safeLoadOrRefreshCache(nimbleCache, keepJson = true):
    raise newException(IOError, "failed to load Nimble cache")

  let binPath = getCachePath() / nimbleCache.binPath
  result = newSeqOfCap[IndexedPackageRecord](4000)
  var nameBuf = newStringOfCap(256)

  withBinaryCache(binPath, name, version):
    nameBuf.setLen(name.len)
    for i in 0 ..< name.len:
      nameBuf[i] = name[i]
    result.add(
      IndexedPackageRecord(
        name: nameBuf,
        version: copyChars(version),
        repo: "nimble",
        installed: installed.hasKey(nameBuf),
      )
    )

proc buildAllSourceIndexes*(outputDir: string): seq[SourceIndexStats] =
  createDir(outputDir)
  let installedMap = loadInstalledMap()
  let nimbleInstalled = loadInstalledNimble()
  result = @[
    buildSourceIndex(
      iskSystem,
      collectSystemPackages(installedMap),
      outputDir / "system.prix",
    ),
    buildSourceIndex(
      iskAur,
      collectAurPackages(installedMap),
      outputDir / "aur.prix",
    ),
    buildSourceIndex(
      iskNimble,
      collectNimblePackages(nimbleInstalled),
      outputDir / "nimble.prix",
    ),
  ]

proc indexFilename(source: IndexedSourceKind): string =
  case source
  of iskSystem:
    "system.prix"
  of iskAur:
    "aur.prix"
  of iskNimble:
    "nimble.prix"

proc ensureRuntimeIndexes*(outputDir: string = defaultRuntimeIndexDir()): seq[ValidatedSourceIndex] =
  var missingOrInvalid = false
  for source in IndexedSourceKind:
    let path = outputDir / indexFilename(source)
    let validated = validateSourceIndex(path)
    result.add(validated)
    if not validated.valid:
      missingOrInvalid = true

  if missingOrInvalid:
    let repoRoot = getCurrentDir()
    let helperBin = repoRoot / "tools/.build_indexes_bin"
    let cmd =
      if fileExists(helperBin):
        quoteShell(helperBin) & " --output-dir=" & quoteShell(outputDir)
      else:
        "bash " & quoteShell(repoRoot / "tools/build_indexes.sh") & " --output-dir=" &
        quoteShell(outputDir)
    let (output, exitCode) = execCmdEx(cmd)
    if exitCode != 0:
      raise newException(IOError, "failed to prepare runtime indexes: " & output)
    result.setLen(0)
    for source in IndexedSourceKind:
      let path = outputDir / indexFilename(source)
      let validated = validateSourceIndex(path)
      if not validated.valid:
        raise newException(IOError, "failed to prepare runtime index: " & path & " (" & validated.error & ")")
      result.add(validated)
