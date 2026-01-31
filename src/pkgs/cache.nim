##
## Unified Cache Manager
##
## Consolidates:
## - Metadata Management (Rotation, download)
## - Binary Cache Format (DOP optimization)
## - Zero-Allocation JSON Parser (Stream-based)
##

import std/[os, osproc, times, streams, parsejson, memfiles, strutils, tables]

const
  CacheDir* = ".cache/parun"
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

  CacheMaxAgeHours* = 24
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

  ZeroAllocCallback* =
    proc(name: openArray[char], version: openArray[char]) {.closure, gcsafe.}

proc validateCacheFile*(path: string): bool =
  ## Validates cache file integrity
  ## Checks: existence, minimum size, magic header
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
  except:
    try:
      fs.close()
    except:
      discard
    return false

proc writeHeader(s: Stream, count: uint32) =
  s.write(BinaryMagic)
  s.write(BinaryVersion.int32)
  s.write(count)

proc convertJsonToBinary*(jsonPath, binPath: string): bool =
  ## Converts a JSON package list to the binary format.
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
  except:
    try:
      parser.close()
      fs.close()
      bs.close()
    except:
      discard
    return false

template withBinaryCache*(binPath: string, nameId, verId, body: untyped) =
  ## Iterates over the binary cache using memory mapping.
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
  ## Zero-allocation JSON stream parser for uncompressed files.
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
    var nameStr: string = ""
    var verStr: string = ""

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        inNameValue = false
        inVersionValue = false
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          if verStr.len == 0:
            verStr = "git"
          callback(nameStr, verStr)
        nameStr = ""
        verStr = ""
        inObject = false
        parser.next()
      of jsonString:
        if inObject and not inNameValue and not inVersionValue:
          currentKey = parser.str
          if currentKey.cmpIgnoreCase("name") == 0:
            inNameValue = true
            inVersionValue = false
          elif currentKey.cmpIgnoreCase("version") == 0:
            inVersionValue = true
            inNameValue = false
          else:
            inNameValue = false
            inVersionValue = false
          parser.next()
        elif inNameValue:
          nameStr = parser.str
          inNameValue = false
          parser.next()
        elif inVersionValue:
          verStr = parser.str
          inVersionValue = false
          parser.next()
        else:
          parser.next()
      else:
        parser.next()

    parser.close()
    fs.close()
    return true
  except:
    try:
      parser.close()
      fs.close()
    except:
      discard
    return false

proc getStreamedNimbleMeta*(jsonPath: string): Table[string, NimbleMeta] =
  result = initTable[string, NimbleMeta]()
  let fs = newFileStream(jsonPath, fmRead)
  if fs == nil:
    return

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    var nameStr = ""
    var urlStr = ""
    var tagsSeq: seq[string] = @[]
    var inTags = false
    var currentKey = ""
    var inObject = false

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        nameStr = ""
        urlStr = ""
        tagsSeq = @[]
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
  except:
    try:
      parser.close()
      fs.close()
    except:
      discard

proc getCachePath*(): string =
  let homeDir = getHomeDir()
  let cacheDir = homeDir / CacheDir
  createDir(cacheDir)
  return cacheDir

proc getCacheStatus*(cache: PackageCache): CacheStatus =
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

proc downloadCompressedGzOnly(url: string, gzOutputPath: string): bool =
  let downloadCmd = "curl -sfL --max-time 60 " & url & " > \"" & gzOutputPath & "\""
  return execCmd(downloadCmd) == 0

proc decompressExistingGz(gzPath: string, outputPath: string): bool =
  let decompressCmd = "gunzip -c \"" & gzPath & "\" > \"" & outputPath & "\""
  return execCmd(decompressCmd) == 0

proc downloadUncompressed(url: string, outputPath: string): bool =
  let downloadCmd = "curl -sfL --max-time 60 " & url & " > \"" & outputPath & "\""
  return execCmd(downloadCmd) == 0

proc validateJsonFile*(path: string): bool =
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
  except:
    try:
      parser.close()
      fs.close()
    except:
      discard
    return false

proc ensureJsonAvailable*(cache: PackageCache): bool =
  let cacheDir = getCachePath()
  let jsonPath = cacheDir / cache.jsonPath
  if fileExists(jsonPath) and validateJsonFile(jsonPath):
    return true
  # Download and validate
  if not downloadUncompressed(cache.metaUrl, jsonPath):
    return false
  return validateJsonFile(jsonPath)

proc refreshCache*(cache: var PackageCache, keepJson: bool = false): bool =
  let cacheDir = getCachePath()
  let jsonPath = cacheDir / cache.jsonPath
  let binPath = cacheDir / cache.binPath
  let stampPath = cacheDir / cache.stampPath

  if cache.gzPath.len > 0:
    let gzPath = cacheDir / cache.gzPath
    if not downloadCompressedGzOnly(cache.metaUrl, gzPath):
      return false
    if not decompressExistingGz(gzPath, jsonPath):
      return false
    removeFile(gzPath)
  else:
    if not downloadUncompressed(cache.metaUrl, jsonPath):
      return false

  # Validate downloaded JSON before conversion
  if not validateJsonFile(jsonPath):
    # Invalid JSON - clean up and fail
    try:
      removeFile(jsonPath)
    except:
      discard
    return false

  if not convertJsonToBinary(jsonPath, binPath):
    return false

  if not keepJson:
    removeFile(jsonPath)
  writeFile(stampPath, $getTime().toUnix())
  return true

proc loadOrRefreshCache*(cache: var PackageCache, keepJson: bool = false): bool =
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
  ## Safely loads cache with validation and automatic cleanup on corruption
  let cacheDir = getCachePath()
  let binPath = cacheDir / cache.binPath

  if not validateCacheFile(binPath):
    # Cache is corrupted or missing, clean up and refresh
    if fileExists(binPath):
      try:
        removeFile(binPath)
      except:
        discard
    let jsonPath = cacheDir / cache.jsonPath
    if fileExists(jsonPath) and not keepJson:
      try:
        removeFile(jsonPath)
      except:
        discard
    return loadOrRefreshCache(cache, keepJson)

  return loadOrRefreshCache(cache, keepJson)

proc initAurCache*(): PackageCache =
  PackageCache(
    jsonPath: AurJsonCache,
    binPath: AurBinCache,
    stampPath: AurStampFile,
    metaUrl: AurMetaUrl,
    maxAge: CacheMaxAgeHours,
    gzPath: AurJsonGzCache,
  )

proc initNimbleCache*(): PackageCache =
  PackageCache(
    jsonPath: NimbleJsonCache,
    binPath: NimbleBinCache,
    stampPath: NimbleStampFile,
    metaUrl: NimbleMetaUrl,
    maxAge: CacheMaxAgeHours,
    gzPath: "",
  )
