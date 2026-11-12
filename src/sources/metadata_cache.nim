import std/[os, parsejson, streams, strutils]

const
  CacheDirName* = "parun"
  CacheDir* = ".cache/parun"
  CacheDirEnvVar = "PARUN_CACHE_DIR"
  AurMetaUrl* = "https://aur.archlinux.org/packages-meta-v1.json.gz"
  NimbleMetaUrl* =
    "https://raw.githubusercontent.com/nim-lang/packages/refs/heads/master/packages.json"
  CacheMaxAgeHours* = 8

type
  ZeroAllocCallback* = proc(
    name: openArray[char], version: openArray[char], url: openArray[char]
  ) {.closure, gcsafe.}

  NimbleRegistryCallback* = proc(
    name, version, url, description, license, web: openArray[char]
  ) {.closure, gcsafe.}

proc streamParseJsonZeroAlloc*(jsonPath: string, callback: ZeroAllocCallback): bool =
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
    true
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard
    false

proc streamParseNimbleRegistryZeroAlloc*(
    jsonPath: string, callback: NimbleRegistryCallback
): bool =
  let fs = newFileStream(jsonPath, fmRead)
  if fs == nil:
    return false

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    var inObject = false
    var inNameValue = false
    var inVersionValue = false
    var inUrlValue = false
    var inDescriptionValue = false
    var inLicenseValue = false
    var inWebValue = false
    var nameStr = ""
    var versionStr = ""
    var urlStr = ""
    var descriptionStr = ""
    var licenseStr = ""
    var webStr = ""

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        inNameValue = false
        inVersionValue = false
        inUrlValue = false
        inDescriptionValue = false
        inLicenseValue = false
        inWebValue = false
        nameStr.setLen(0)
        versionStr.setLen(0)
        urlStr.setLen(0)
        descriptionStr.setLen(0)
        licenseStr.setLen(0)
        webStr.setLen(0)
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          if versionStr.len == 0:
            versionStr = "git"
          callback(nameStr, versionStr, urlStr, descriptionStr, licenseStr, webStr)
        inObject = false
        parser.next()
      of jsonString:
        if inObject and not inNameValue and not inVersionValue and not inUrlValue and
            not inDescriptionValue and not inLicenseValue and not inWebValue:
          let key = parser.str
          inNameValue = key.cmpIgnoreCase("name") == 0
          inVersionValue = key.cmpIgnoreCase("version") == 0
          inUrlValue = key.cmpIgnoreCase("url") == 0
          inDescriptionValue = key.cmpIgnoreCase("description") == 0
          inLicenseValue = key.cmpIgnoreCase("license") == 0
          inWebValue = key.cmpIgnoreCase("web") == 0
          parser.next()
        elif inNameValue:
          nameStr = parser.str
          inNameValue = false
          parser.next()
        elif inVersionValue:
          versionStr = parser.str
          inVersionValue = false
          parser.next()
        elif inUrlValue:
          urlStr = parser.str
          inUrlValue = false
          parser.next()
        elif inDescriptionValue:
          descriptionStr = parser.str
          inDescriptionValue = false
          parser.next()
        elif inLicenseValue:
          licenseStr = parser.str
          inLicenseValue = false
          parser.next()
        elif inWebValue:
          webStr = parser.str
          inWebValue = false
          parser.next()
        else:
          parser.next()
      else:
        inNameValue = false
        inVersionValue = false
        inUrlValue = false
        inDescriptionValue = false
        inLicenseValue = false
        inWebValue = false
        parser.next()

    parser.close()
    fs.close()
    true
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard
    false

proc getCachePath*(): string =
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
  cacheDir

proc validateJsonFile*(path: string): bool =
  if not fileExists(path):
    return false

  let fs = newFileStream(path, fmRead)
  if fs == nil:
    return false

  var parser: JsonParser
  try:
    parser.open(fs, path)
    parser.next()
    let kind = parser.kind
    parser.close()
    fs.close()
    kind == jsonArrayStart or kind == jsonObjectStart
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard
    false
