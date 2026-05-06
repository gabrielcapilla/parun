## Nimble metadata parsing and normalization helpers.
##
## Local Nimble search output is used only as a partial fallback. Complete
## details come from the package repository `.nimble` file when available.
import std/[strutils]

const NimbleRawBranches = ["master", "main"]

type NimblePackageInfo = object
  name: string
  version: string
  description: string
  author: string
  license: string
  url: string
  requires: seq[string]

func stripVcsSuffix(value: string): string =
  result = value.strip()
  var last = result.len
  while last > 0 and result[last - 1] == '/':
    dec last
  if last != result.len:
    result.setLen(last)
  if result.endsWith(" (git)") or result.endsWith(" (hg)"):
    result.setLen(result.len - 6)
  if result.endsWith(".git"):
    result.setLen(result.len - 4)

func getRawBaseUrl*(repoUrl: string): string {.noSideEffect.} =
  ## Converts repository URL to a raw-content base URL for known hosts.
  let cleanUrl = repoUrl.stripVcsSuffix()
  if cleanUrl.len == 0:
    return ""

  if "github.com" in cleanUrl:
    return cleanUrl.replace("github.com", "raw.githubusercontent.com")
  if "gitlab.com" in cleanUrl:
    return cleanUrl & "/-/raw"
  if "codeberg.org" in cleanUrl:
    return cleanUrl & "/raw/branch"
  return ""

func addNimbleFileNames(dst: var seq[string], pkgName: string) =
  dst.add(pkgName & ".nimble")
  let lowerName = pkgName.toLowerAscii()
  if lowerName != pkgName:
    dst.add(lowerName & ".nimble")

func getRawNimbleFileCandidates*(
    repoUrl, pkgName: string
): seq[string] {.noSideEffect.} =
  ## Builds raw manifest URLs for the supported repository hosts.
  ##
  ## GitHub accepts both `/refs/heads/<branch>/...` and `/<branch>/...`; the
  ## refs form is tried first because it maps directly to the selected branch.
  let base = getRawBaseUrl(repoUrl)
  if base.len == 0 or pkgName.len == 0:
    return @[]

  var files = newSeqOfCap[string](2)
  files.addNimbleFileNames(pkgName)

  result = newSeqOfCap[string](NimbleRawBranches.len * files.len * 2)
  for branch in NimbleRawBranches:
    for fileName in files:
      if "raw.githubusercontent.com" in base:
        result.add(base & "/refs/heads/" & branch & "/" & fileName)
      result.add(base & "/" & branch & "/" & fileName)

func unquoteValue(value: string): string =
  result = value.strip()
  if result.len >= 2:
    let first = result[0]
    let last = result[^1]
    if (first == '"' and last == '"') or (first == '\'' and last == '\''):
      result = result[1 ..^ 2]

func startsWithAsciiNoCase(value, prefix: string): bool {.inline.} =
  if value.len < prefix.len:
    return false
  for i in 0 ..< prefix.len:
    if value[i].toLowerAscii() != prefix[i]:
      return false
  true

func isRequiresDecl(value: string): bool {.inline.} =
  value.startsWithAsciiNoCase("requires") and
    (value.len == 8 or value[8] in {' ', '\t', ':'})

func addRequires(info: var NimblePackageInfo, rawValue: string) =
  var rest = rawValue.strip()
  if rest.startsWith("(") and rest.endsWith(")"):
    rest = rest[1 ..^ 2]
  for part in rest.split(','):
    let dep = part.unquoteValue()
    if dep.len > 0:
      info.requires.add(dep)

func parseNimbleFile(raw, name, repoUrl: string): NimblePackageInfo =
  result.name = name
  result.url = repoUrl.stripVcsSuffix()
  result.requires = newSeqOfCap[string](16)

  for line in raw.splitLines():
    var first = 0
    while first < line.len and line[first] in {' ', '\t', '\r'}:
      inc first
    if first == line.len or line[first] == '#':
      continue

    let cleaned = line[first ..^ 1].strip()
    if cleaned.isRequiresDecl():
      let rawRequires =
        if ':' in cleaned:
          cleaned.split(':', 1)[1]
        elif cleaned.len > 8:
          cleaned[8 ..^ 1]
        else:
          ""
      result.addRequires(rawRequires)
      continue

    if '=' notin cleaned:
      continue
    let parts = cleaned.split('=', 1)
    let key = parts[0].strip().toLowerAscii()
    let val = parts[1].unquoteValue()
    case key
    of "version":
      result.version = val
    of "description":
      result.description = val
    of "author":
      result.author = val
    of "license", "licenses":
      result.license = val
    else:
      discard

func addField(dst: var string, key, value: string) =
  if value.len > 0:
    dst.add(key)
    dst.add(" : ")
    dst.add(value)
    dst.add('\n')

func addRequiredField(dst: var string, key, value: string) =
  dst.add(key)
  dst.add(" : ")
  dst.add(value)
  dst.add('\n')

func formatRepositoryNimbleInfo(info: NimblePackageInfo): string =
  result = newStringOfCap(384)
  result.addRequiredField("Repository     ", "nimble")
  result.addRequiredField("Name           ", info.name)
  result.addRequiredField("Version        ", info.version)
  result.addRequiredField("Description    ", info.description)
  result.addRequiredField("URL            ", info.url)
  result.addRequiredField("Licenses       ", info.license)
  result.addRequiredField("Author         ", info.author)
  result.addRequiredField("Depends On     ", info.requires.join(", "))

func formatFallbackNimbleInfo(info: NimblePackageInfo): string =
  result = newStringOfCap(256)
  result.addField("Repository     ", "nimble")
  result.addField("Name           ", info.name)
  result.addField("Description    ", info.description)
  result.addField("URL            ", info.url)
  result.addField("Licenses       ", info.license)

func parseNimbleInfo*(
    raw, name, url: string, tagsLine: string
): string {.noSideEffect.} =
  ## Parses repository `.nimble` content into details-panel text.
  discard tagsLine
  parseNimbleFile(raw, name, url).formatRepositoryNimbleInfo()

func parseNimbleInfo*(
    raw, name, url: string, tags: seq[string]
): string {.noSideEffect.} =
  discard tags
  parseNimbleFile(raw, name, url).formatRepositoryNimbleInfo()

func formatFallbackInfo*(raw: string): string {.noSideEffect.} =
  ## Parses partial `nimble search` output when repository `.nimble` fetch fails.
  var info = NimblePackageInfo(requires: newSeqOfCap[string](0))
  for line in raw.splitLines():
    let stripped = line.strip()
    if stripped.len == 0:
      continue
    if not line.startsWith(" ") and stripped.endsWith(":"):
      info.name = stripped[0 ..^ 2]
      continue
    if ':' notin stripped:
      continue
    let parts = stripped.split(':', 1)
    let key = parts[0].strip().toLowerAscii()
    let val = parts[1].strip()
    case key
    of "url":
      info.url = val.stripVcsSuffix()
    of "description":
      info.description = val
    of "license":
      info.license = val
    else:
      discard

  result = info.formatFallbackNimbleInfo()
