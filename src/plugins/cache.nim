##
## Unified cache manager.
##
## Consolidates:
## - Metadata fetch/rotation for AUR and Nimble package lists.
## - Legacy packed binary metadata used by fallback detail paths.
## - Streaming JSON parsing used by `.prix` index construction.
##
## Notes:
## - This module is the persistence boundary for AUR/Nimble metadata.
## - Runtime search uses immutable `.prix` indexes. Current Nimble details use
##   repository URLs embedded in `nimble.prix`; `packages.json`/`packages.bin`
##   are only needed by legacy fallback paths or explicit cache refreshes.
##

import std/[os, osproc, times, streams, parsejson, memfiles, strutils, tables]

const
  CacheDirName* = "parun"
  CacheDir* = ".cache/parun"
  CacheDirEnvVar = "PARUN_CACHE_DIR"
  AurJsonCache* = "aur-meta.json"
  AurBinCache* = "aur-meta.bin"
  AurJsonGzCache* = "aur-meta.json.gz"
  AurStampFile* = "aur-meta.json.stamp"
  AurMetaUrl* = "https://aur.archlinux.org/packages-meta-v1.json.gz"

  NimbleJsonCache* = "packages.json"
  NimbleBinCache* = "packages.bin"
  NimbleStampFile* = "packages.json.stamp"
  NimbleMetaUrl* =
    "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"

  CacheMaxAgeHours* = 8
  BinaryMagic = "PARU"
  BinaryVersion = 2

type
  CacheStatus* = enum
    CacheFresh
    CacheStale
    CacheMissing

  PackageCache* = object
    jsonPath*: string
    binPath*: string
    stampPath*: string
    metaUrl*: string
    maxAge*: int
    gzPath*: string

  NimbleMeta* = tuple[url: string, tags: seq[string]]

  ZeroAllocCallback* = proc(
    name: openArray[char], version: openArray[char], url: openArray[char]
  ) {.closure, gcsafe.}

proc safeRemove(path: string) =
  if not fileExists(path):
    return
  try:
    removeFile(path)
  except CatchableError:
    discard

proc tempSiblingPath(path: string, suffix: string): string =
  let millis = int64(epochTime() * 1000.0)
  path & "." & suffix & "." & $getCurrentProcessId() & "." & $millis & ".tmp"

proc atomicReplace(srcPath: string, dstPath: string): bool =
  try:
    moveFile(srcPath, dstPath)
    return true
  except CatchableError:
    try:
      safeRemove(dstPath)
      moveFile(srcPath, dstPath)
      return true
    except CatchableError:
      safeRemove(srcPath)
      return false

proc validateCacheFile*(path: string): bool =
  ## Validates binary cache structure.
  ## Checks: existence, minimum size, magic header + version.
  if not fileExists(path):
    return false

  let size = getFileSize(path)
  if size < 16: # Minimum: 4 (magic) + 4 (version) + 4 (count) + at least 4 bytes data
    return false

  # Validate magic header
  var fs = newFileStream(path, fmRead)
  if fs == nil:
    return false

  var magic: array[4, char]
  try:
    if fs.readData(addr magic[0], 4) != 4:
      fs.close()
      return false
    fs.close()

    # Check magic bytes
    if magic[0] != 'P' or magic[1] != 'A' or magic[2] != 'R' or magic[3] != 'U':
      return false

    return true
  except CatchableError:
    try:
      fs.close()
    except CatchableError:
      discard
    return false

proc writeHeader(s: Stream, count: uint32) =
  s.write(BinaryMagic)
  s.write(BinaryVersion.int32)
  s.write(count)

proc convertJsonToBinary*(jsonPath, binPath: string): bool =
  ## Converts metadata JSON to compact binary cache format.
  ## This legacy format stores package name/version pairs and is not the primary
  ## runtime search index.
  var fs = newFileStream(jsonPath, fmRead)
  if fs == nil:
    return false

  var bs = newFileStream(binPath, fmWrite)
  if bs == nil:
    fs.close()
    return false

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    writeHeader(bs, 0) # Placeholder

    var count: uint32 = 0
    var nameStr: string = ""
    var verStr: string = ""
    var inObject = false
    var inName = false
    var inVer = false

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          if verStr.len == 0:
            verStr = "git"
          if nameStr.len > 255:
            nameStr.setLen(255)
          if verStr.len > 255:
            verStr.setLen(255)

          bs.write(nameStr.len.uint8)
          bs.write(nameStr)
          bs.write(verStr.len.uint8)
          bs.write(verStr)
          count.inc()

        nameStr = ""
        verStr = ""
        inObject = false
        parser.next()
      of jsonString:
        if inObject:
          if not inName and not inVer:
            if parser.str.cmpIgnoreCase("name") == 0:
              inName = true
            elif parser.str.cmpIgnoreCase("version") == 0:
              inVer = true
          elif inName:
            nameStr = parser.str
            inName = false
          elif inVer:
            verStr = parser.str
            inVer = false
        parser.next()
      else:
        parser.next()

    bs.setPosition(0)
    writeHeader(bs, count)

    parser.close()
    fs.close()
    bs.close()
    return true
  except CatchableError:
    try:
      parser.close()
      fs.close()
      bs.close()
    except CatchableError:
      discard
    return false

template withBinaryCache*(binPath: string, nameId, verId, body: untyped) =
  ## Iterates binary cache entries with zero per-entry string allocation.
  ## The mapped format contains name/version slices only.
  if fileExists(binPath):
    var mf = memfiles.open(binPath)
    if mf.mem != nil:
      let ptrMem = cast[ptr UncheckedArray[byte]](mf.mem)
      var offset = 0

      if mf.size > 12 and ptrMem[0].char == 'P' and ptrMem[1].char == 'A' and
          ptrMem[2].char == 'R' and ptrMem[3].char == 'U':
        offset += 4 # Skip Magic

        let fileVer = cast[ptr int32](addr ptrMem[offset])[]
        offset += 4 # Skip Version

        if fileVer == BinaryVersion:
          let count = cast[ptr uint32](addr ptrMem[offset])[]
          offset += 4

          var i: uint32 = 0
          while i < count and offset < mf.size:
            let nLen = ptrMem[offset].int
            offset.inc()
            let namePtr = addr ptrMem[offset]
            offset += nLen

            let vLen = ptrMem[offset].int
            offset.inc()
            let verPtr = addr ptrMem[offset]
            offset += vLen

            template nameId(): untyped =
              toOpenArray(cast[ptr UncheckedArray[char]](namePtr), 0, nLen - 1)

            template verId(): untyped =
              toOpenArray(cast[ptr UncheckedArray[char]](verPtr), 0, vLen - 1)

            body

            i.inc()

      mf.close()

proc streamParseJsonZeroAlloc*(jsonPath: string, callback: ZeroAllocCallback): bool =
  ## Streams large metadata JSON and emits `(name, version, url)` slices.
  ## The parser is used while building `.prix` files and avoids per-package
  ## object allocation for uncompressed package-list JSON.
  let fs = newFileStream(jsonPath, fmRead)
  if fs == nil:
    return false

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    var inObject = false
    var currentKey = ""
    var inNameValue = false
    var inVersionValue = false
    var inUrlValue = false
    var nameStr: string = ""
    var verStr: string = ""
    var urlStr: string = ""

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        inNameValue = false
        inVersionValue = false
        inUrlValue = false
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          if verStr.len == 0:
            verStr = "git"
          callback(nameStr, verStr, urlStr)
        nameStr = ""
        verStr = ""
        urlStr = ""
        inObject = false
        parser.next()
      of jsonString:
        if inObject and not inNameValue and not inVersionValue and not inUrlValue:
          currentKey = parser.str
          if currentKey.cmpIgnoreCase("name") == 0:
            inNameValue = true
            inVersionValue = false
            inUrlValue = false
          elif currentKey.cmpIgnoreCase("version") == 0:
            inVersionValue = true
            inNameValue = false
            inUrlValue = false
          elif currentKey.cmpIgnoreCase("url") == 0:
            inNameValue = false
            inVersionValue = false
            inUrlValue = true
          else:
            inNameValue = false
            inVersionValue = false
            inUrlValue = false
          parser.next()
        elif inNameValue:
          nameStr = parser.str
          inNameValue = false
          parser.next()
        elif inVersionValue:
          verStr = parser.str
          inVersionValue = false
          parser.next()
        elif inUrlValue:
          urlStr = parser.str
          inUrlValue = false
          parser.next()
        else:
          parser.next()
      else:
        parser.next()

    parser.close()
    fs.close()
    return true
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard
    return false

proc getStreamedNimbleMeta*(jsonPath: string): Table[string, NimbleMeta] =
  ## Extracts Nimble package URL/tags map from JSON.
  result = initTable[string, NimbleMeta]()
  let fs = newFileStream(jsonPath, fmRead)
  if fs == nil:
    return

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    var nameStr = ""
    var urlStr = ""
    var tagsSeq = newSeqOfCap[string](10)
    var inTags = false
    var currentKey = ""
    var inObject = false

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        nameStr.setLen(0)
        urlStr.setLen(0)
        tagsSeq.setLen(0)
        currentKey.setLen(0)
        inTags = false
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          result[nameStr] = (url: urlStr, tags: tagsSeq)
        inObject = false
        parser.next()
      of jsonString:
        if inObject:
          if inTags:
            tagsSeq.add(parser.str)
          else:
            # Check if this string is a value for a known key
            if currentKey.len > 0:
              if currentKey.cmpIgnoreCase("name") == 0:
                nameStr = parser.str
              elif currentKey.cmpIgnoreCase("url") == 0:
                urlStr = parser.str
              # Reset key after consuming value
              currentKey = ""
            else:
              # This string is a key
              currentKey = parser.str
        parser.next()
      of jsonArrayStart:
        if currentKey.cmpIgnoreCase("tags") == 0:
          inTags = true
          currentKey = "" # Reset key
        parser.next()
      of jsonArrayEnd:
        inTags = false
        parser.next()
      else:
        # Clear key if we hit something else (like null, int, etc which shouldn't happen for name/url but good for safety)
        if parser.kind != jsonString:
          currentKey = ""
        parser.next()
    parser.close()
    fs.close()
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard

proc getCachePath*(): string =
  ## Resolves cache root path, honoring `PARUN_CACHE_DIR` when set.
  let envOverride = getEnv(CacheDirEnvVar, "").strip()
  let cacheDir =
    if envOverride.len > 0:
      envOverride
    else:
      let xdgCache = getEnv("XDG_CACHE_HOME", "").strip()
      if xdgCache.len > 0:
        xdgCache / CacheDirName
      else:
        getHomeDir() / ".cache" / CacheDirName
  createDir(cacheDir)
  return cacheDir

proc getCacheStatus*(cache: PackageCache): CacheStatus =
  ## Returns freshness status from presence + age checks.
  let cacheDir = getCachePath()
  let binPath = cacheDir / cache.binPath
  let stampPath = cacheDir / cache.stampPath

  if not fileExists(binPath):
    return CacheMissing
  if not fileExists(stampPath):
    return CacheStale

  let stampTime = getLastModificationTime(stampPath)
  let ageHours = (getTime() - stampTime).inHours

  if ageHours >= cache.maxAge:
    return CacheStale
  return CacheFresh

proc downloadToPath(url: string, outputPath: string): bool =
  let downloadCmd = "curl -sfL --max-time 60 " & url & " > \"" & outputPath & "\""
  return execCmd(downloadCmd) == 0

proc downloadCompressedGzOnly(url: string, gzOutputPath: string): bool =
  return downloadToPath(url, gzOutputPath)

proc decompressExistingGz(gzPath: string, outputPath: string): bool =
  let decompressCmd = "gunzip -c \"" & gzPath & "\" > \"" & outputPath & "\""
  return execCmd(decompressCmd) == 0

proc downloadUncompressed(url: string, outputPath: string): bool =
  return downloadToPath(url, outputPath)

proc validateJsonFile*(path: string): bool =
  ## Performs lightweight JSON validity probe.
  ## Validates that a file contains valid JSON
  ## Used as integrity check for downloaded metadata
  if not fileExists(path):
    return false

  let fs = newFileStream(path, fmRead)
  if fs == nil:
    return false

  var parser: JsonParser
  try:
    parser.open(fs, path)
    # Try to parse the first token to validate JSON structure
    parser.next()
    let kind = parser.kind
    parser.close()
    fs.close()
    # Valid JSON starts with array or object
    return kind == jsonArrayStart or kind == jsonObjectStart
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard
    return false

proc ensureJsonAvailable*(cache: PackageCache): bool =
  ## Ensures JSON metadata file exists locally (download if missing).
  let cacheDir = getCachePath()
  let jsonPath = cacheDir / cache.jsonPath
  if fileExists(jsonPath) and validateJsonFile(jsonPath):
    return true
  let downloadPath = tempSiblingPath(jsonPath, "download")
  defer:
    safeRemove(downloadPath)
  if not downloadUncompressed(cache.metaUrl, downloadPath):
    return false
  if not validateJsonFile(downloadPath):
    return false
  return atomicReplace(downloadPath, jsonPath)

proc refreshCache*(cache: var PackageCache, keepJson: bool = false): bool =
  ## Refreshes cache from network source and rebuilds binary snapshot.
  let cacheDir = getCachePath()
  let jsonPath = cacheDir / cache.jsonPath
  let binPath = cacheDir / cache.binPath
  let stampPath = cacheDir / cache.stampPath
  let tempJsonPath = tempSiblingPath(jsonPath, "json")
  let tempBinPath = tempSiblingPath(binPath, "bin")
  let tempStampPath = tempSiblingPath(stampPath, "stamp")
  let tempGzPath =
    if cache.gzPath.len > 0:
      tempSiblingPath(cacheDir / cache.gzPath, "gz")
    else:
      ""

  defer:
    safeRemove(tempJsonPath)
    safeRemove(tempBinPath)
    safeRemove(tempStampPath)
    if tempGzPath.len > 0:
      safeRemove(tempGzPath)

  if cache.gzPath.len > 0:
    if not downloadCompressedGzOnly(cache.metaUrl, tempGzPath):
      return false
    if not decompressExistingGz(tempGzPath, tempJsonPath):
      return false
  else:
    if not downloadUncompressed(cache.metaUrl, tempJsonPath):
      return false

  # Validate downloaded JSON before conversion
  if not validateJsonFile(tempJsonPath):
    return false

  if not convertJsonToBinary(tempJsonPath, tempBinPath):
    return false
  if not validateCacheFile(tempBinPath):
    return false
  if not atomicReplace(tempBinPath, binPath):
    return false

  if keepJson:
    if not atomicReplace(tempJsonPath, jsonPath):
      return false
  else:
    safeRemove(jsonPath)

  try:
    writeFile(tempStampPath, $getTime().toUnix())
  except CatchableError:
    return false
  if not atomicReplace(tempStampPath, stampPath):
    return false
  return true

proc loadOrRefreshCache*(cache: var PackageCache, keepJson: bool = false): bool =
  ## Fast path: validate current binary, otherwise refresh.
  let cacheDir = getCachePath()
  let binPath = cacheDir / cache.binPath

  case getCacheStatus(cache)
  of CacheFresh:
    return fileExists(binPath)
  of CacheStale:
    if refreshCache(cache, keepJson):
      return true
    return fileExists(binPath)
  of CacheMissing:
    return refreshCache(cache, keepJson)

proc safeLoadOrRefreshCache*(cache: var PackageCache, keepJson: bool = false): bool =
  ## Same as `loadOrRefreshCache` but swallows recoverable exceptions.
  ## Safely loads cache with validation and automatic cleanup on corruption
  let cacheDir = getCachePath()
  let binPath = cacheDir / cache.binPath

  if not validateCacheFile(binPath):
    # Cache is corrupted or missing, clean up and refresh
    if fileExists(binPath):
      try:
        removeFile(binPath)
      except CatchableError:
        discard
    let jsonPath = cacheDir / cache.jsonPath
    if fileExists(jsonPath) and not keepJson:
      try:
        removeFile(jsonPath)
      except CatchableError:
        discard
    return loadOrRefreshCache(cache, keepJson)

  return loadOrRefreshCache(cache, keepJson)

proc initAurCache*(): PackageCache =
  ## Constructs AUR cache descriptor.
  PackageCache(
    jsonPath: AurJsonCache,
    binPath: AurBinCache,
    stampPath: AurStampFile,
    metaUrl: AurMetaUrl,
    maxAge: CacheMaxAgeHours,
    gzPath: AurJsonGzCache,
  )

proc initNimbleCache*(): PackageCache =
  ## Constructs Nimble cache descriptor.
  PackageCache(
    jsonPath: NimbleJsonCache,
    binPath: NimbleBinCache,
    stampPath: NimbleStampFile,
    metaUrl: NimbleMetaUrl,
    maxAge: CacheMaxAgeHours,
    gzPath: "",
  )
