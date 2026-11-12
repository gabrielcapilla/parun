import std/[algorithm, os, sets, strutils, tables, times]

const LocalDbPath* = "/var/lib/pacman/local"

proc findLocalPackageDir*(name: string, localDbPath: string = LocalDbPath): string =
  if not dirExists(localDbPath):
    return ""
  for kind, pkgDir in walkDir(localDbPath):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let descPath = pkgDir / "desc"
    var wantName = false
    try:
      for line in lines(descPath):
        if wantName:
          if line.len > 0:
            if line == name:
              return pkgDir
            break
          return ""
        elif line == "%NAME%":
          wantName = true
    except CatchableError:
      discard
  ""

proc parseDescText*(content: string): Table[string, seq[string]] =
  result = initTable[string, seq[string]]()
  var current = ""
  for line in content.splitLines():
    if line.len > 2 and line[0] == '%' and line[^1] == '%':
      current = line[1 ..^ 2]
      result[current] = @[]
    elif current.len > 0 and line.len > 0:
      result[current].add(line)

proc readDescSections*(pkgDir: string): Table[string, seq[string]] =
  try:
    return parseDescText(readFile(pkgDir / "desc"))
  except CatchableError:
    return initTable[string, seq[string]]()

proc field*(sections: Table[string, seq[string]], name: string): string =
  if sections.hasKey(name) and sections[name].len > 0:
    sections[name][0]
  else:
    ""

proc appendPacmanDetailRow*(outRes: var string, label, value: string) {.inline.} =
  outRes.add(label.alignLeft(16))
  outRes.add(": ")
  outRes.add(value)
  outRes.add("\n")

proc appendPacmanListField*(
    outRes: var string, sections: Table[string, seq[string]], fieldName, label: string
) =
  let value =
    if sections.hasKey(fieldName) and sections[fieldName].len > 0:
      sections[fieldName].join("  ")
    else:
      "None"
  appendPacmanDetailRow(outRes, label, value)

proc orNone*(value: string): string =
  if value.len == 0: "None" else: value

proc appendPacmanCommonFields*(
    outRes: var string, sections: Table[string, seq[string]]
) =
  appendPacmanDetailRow(outRes, "Name", field(sections, "NAME"))
  appendPacmanDetailRow(outRes, "Version", field(sections, "VERSION"))
  appendPacmanDetailRow(outRes, "Description", field(sections, "DESC"))
  appendPacmanDetailRow(outRes, "Architecture", field(sections, "ARCH"))
  appendPacmanDetailRow(outRes, "URL", orNone(field(sections, "URL")))
  for (key, label) in [
    ("LICENSE", "Licenses"),
    ("GROUPS", "Groups"),
    ("PROVIDES", "Provides"),
    ("DEPENDS", "Depends On"),
  ]:
    appendPacmanListField(outRes, sections, key, label)

proc humanizeParts*(bytes: int64): tuple[value: string, unit: int] =
  const names = ["B", "KiB", "MiB", "GiB", "TiB"]
  if bytes < 1024:
    return ($bytes, 0)
  var value = bytes.float / 1024.0
  var unit = 1
  while value >= 2048.0 and unit < names.len - 1:
    value /= 1024.0
    inc unit
  (formatFloat(value, ffDecimal, 2), unit)

proc humanizeSize*(bytes: int64): string =
  const names = ["B", "KiB", "MiB", "GiB", "TiB"]
  let (value, unit) = humanizeParts(bytes)
  value & " " & names[unit]

proc ctimeFormat*(ts: int64): string =
  let dt = fromUnix(ts).local
  const days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  const months =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  let day =
    if dt.monthday < 10:
      " " & $dt.monthday
    else:
      $dt.monthday
  days[dt.weekday.ord] & " " & months[dt.month.ord - 1] & " " & day & " " &
    ($dt.hour).align(2, '0') & ":" & ($dt.minute).align(2, '0') & ":" &
    ($dt.second).align(2, '0') & " " & $dt.year

proc validationMethod(value: string): string =
  case value.strip().toLowerAscii()
  of "pgp": "Signature"
  of "md5", "md5sum": "MD5 Sum"
  of "sha256", "sha256sum": "SHA-256 Sum"
  of "sha512", "sha512sum": "SHA-512 Sum"
  of "none", "": "None"
  else: "Unknown"

proc validationLabels(sections: Table[string, seq[string]]): string =
  if not sections.hasKey("VALIDATION") or sections["VALIDATION"].len == 0:
    return "None"
  var labels: seq[string] = @[]
  for entry in sections["VALIDATION"]:
    labels.add(validationMethod(entry))
  labels.join("  ")

type ReverseDepIndex* = object
  requiredBy*: Table[string, seq[string]]
  optionalFor*: Table[string, seq[string]]
  satisfied*: HashSet[string]

  dirByName*: Table[string, string]

func depBaseName*(entry: string): string =
  for i, ch in entry:
    if ch in {'=', '<', '>', '!'}:
      return entry[0 ..< i]
  entry

proc buildReverseDepIndex*(localDbPath: string = LocalDbPath): ReverseDepIndex =
  var directDeps: Table[string, seq[string]] = initTable[string, seq[string]]()
  var directOpts: Table[string, seq[string]] = initTable[string, seq[string]]()
  var provByName: Table[string, seq[string]] = initTable[string, seq[string]]()
  var provSonameExact: Table[string, seq[string]] = initTable[string, seq[string]]()
  var provSonameBase: Table[string, seq[string]] = initTable[string, seq[string]]()
  result.satisfied = initHashSet[string]()
  result.dirByName = initTable[string, string]()
  if not dirExists(localDbPath):
    return result
  for kind, pkgDir in walkDir(localDbPath):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    try:
      let sections = readDescSections(pkgDir)
      let name = field(sections, "NAME")
      if name.len == 0:
        continue
      result.dirByName[name] = pkgDir
      result.satisfied.incl(name)
      if sections.hasKey("PROVIDES"):
        for entry in sections["PROVIDES"]:
          let full = entry.strip()
          if full.len == 0:
            continue
          result.satisfied.incl(depBaseName(full))
          if ".so" in full:
            if not provSonameExact.hasKey(full):
              provSonameExact[full] = @[]
            if name notin provSonameExact[full]:
              provSonameExact[full].add(name)
            let eq = full.find('=')
            let base =
              if eq > 0:
                full[0 ..< eq]
              else:
                full
            if not provSonameBase.hasKey(base):
              provSonameBase[base] = @[]
            if name notin provSonameBase[base]:
              provSonameBase[base].add(name)
          else:
            let base = depBaseName(full)
            if base.len > 0:
              if not provByName.hasKey(base):
                provByName[base] = @[]
              if name notin provByName[base]:
                provByName[base].add(name)
      if sections.hasKey("DEPENDS"):
        for entry in sections["DEPENDS"]:
          let full = entry.strip()
          if full.len > 0:
            if not directDeps.hasKey(full):
              directDeps[full] = @[]
            if name notin directDeps[full]:
              directDeps[full].add(name)
      if sections.hasKey("OPTDEPENDS"):
        for entry in sections["OPTDEPENDS"]:
          let colon = entry.find(':')
          let full = (if colon > 0: entry[0 ..< colon] else: entry).strip()
          if full.len > 0:
            if not directOpts.hasKey(full):
              directOpts[full] = @[]
            if name notin directOpts[full]:
              directOpts[full].add(name)
    except CatchableError:
      discard
  proc providersOf(depEntry: string): seq[string] =
    if ".so" in depEntry:
      let eq = depEntry.find('=')
      if eq > 0:
        return provSonameExact.getOrDefault(depEntry, @[])
      result = @[depEntry]
      for provider in provSonameBase.getOrDefault(depEntry, @[]):
        if provider notin result:
          result.add(provider)
      return result
    let base = depBaseName(depEntry)
    result = @[base]
    for provider in provByName.getOrDefault(base, @[]):
      if provider notin result:
        result.add(provider)

  result.requiredBy = initTable[string, seq[string]]()
  result.optionalFor = initTable[string, seq[string]]()
  for dep, users in directDeps.pairs:
    for holder in providersOf(dep):
      if not result.requiredBy.hasKey(holder):
        result.requiredBy[holder] = @[]
      for user in users:
        if user notin result.requiredBy[holder]:
          result.requiredBy[holder].add(user)
  for dep, users in directOpts.pairs:
    for holder in providersOf(dep):
      if not result.optionalFor.hasKey(holder):
        result.optionalFor[holder] = @[]
      for user in users:
        if user notin result.optionalFor[holder]:
          result.optionalFor[holder].add(user)
  for key in result.requiredBy.keys:
    result.requiredBy[key] = sorted(result.requiredBy[key])
  for key in result.optionalFor.keys:
    result.optionalFor[key] = sorted(result.optionalFor[key])

proc formatOptDepends(
    sections: Table[string, seq[string]], satisfied: HashSet[string]
): string =
  if not sections.hasKey("OPTDEPENDS") or sections["OPTDEPENDS"].len == 0:
    return "None"
  var lines: seq[string] = @[]
  for entry in sections["OPTDEPENDS"]:
    let colon = entry.find(':')
    let depName =
      if colon > 0:
        entry[0 ..< colon]
      else:
        entry
    var text = entry
    if depName in satisfied:
      text.add(" [installed]")
    lines.add(text)
  lines.join("\n" & repeat(' ', 18))

proc formatLocalDetails*(pkgDir: string, revdeps: ReverseDepIndex): string =
  if pkgDir.len == 0 or not fileExists(pkgDir / "desc"):
    return ""
  let sections = readDescSections(pkgDir)
  if field(sections, "NAME").len == 0:
    return ""
  let pkgName = field(sections, "NAME")
  var outRes = ""

  appendPacmanDetailRow(
    outRes, "Installed From", orNone(field(sections, "INSTALLED_DB"))
  )
  appendPacmanCommonFields(outRes, sections)
  appendPacmanDetailRow(
    outRes, "Optional Deps", formatOptDepends(sections, revdeps.satisfied)
  )
  if revdeps.requiredBy.hasKey(pkgName):
    appendPacmanDetailRow(outRes, "Required By", revdeps.requiredBy[pkgName].join("  "))
  else:
    appendPacmanDetailRow(outRes, "Required By", "None")
  if revdeps.optionalFor.hasKey(pkgName):
    appendPacmanDetailRow(
      outRes, "Optional For", revdeps.optionalFor[pkgName].join("  ")
    )
  else:
    appendPacmanDetailRow(outRes, "Optional For", "None")
  for key in ["CONFLICTS", "REPLACES"]:
    let label = if key == "CONFLICTS": "Conflicts With" else: "Replaces"
    appendPacmanListField(outRes, sections, key, label)
  var sizeBytes: int64 = 0
  try:
    sizeBytes = parseInt(field(sections, "SIZE")).int64
  except ValueError:
    discard
  appendPacmanDetailRow(outRes, "Installed Size", humanizeSize(sizeBytes))
  appendPacmanDetailRow(outRes, "Packager", field(sections, "PACKAGER"))
  var buildTs, installTs: int64 = 0
  try:
    buildTs = parseInt(field(sections, "BUILDDATE")).int64
  except ValueError:
    discard
  try:
    installTs = parseInt(field(sections, "INSTALLDATE")).int64
  except ValueError:
    discard
  appendPacmanDetailRow(outRes, "Build Date", ctimeFormat(buildTs))
  appendPacmanDetailRow(outRes, "Install Date", ctimeFormat(installTs))
  appendPacmanDetailRow(
    outRes,
    "Install Reason",
    if field(sections, "REASON") == "1":
      "Installed as a dependency for another package"
    else:
      "Explicitly installed",
  )
  appendPacmanDetailRow(
    outRes, "Install Script", if fileExists(pkgDir / "install"): "Yes" else: "No"
  )
  appendPacmanDetailRow(outRes, "Validated By", validationLabels(sections))

  outRes.add("\n")
  outRes
