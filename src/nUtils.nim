## Pure functions to parse `.nimble` files and repository URLs.

import std/[strutils, tables]

func getRawBaseUrl*(repoUrl: string): string {.noSideEffect.} =
  ## Converts a repo URL (GitHub, GitLab, etc.) into its "raw" URL
  ## for downloading individual files. (I tried!)
  var cleanUrl = repoUrl.strip()

  if cleanUrl.endsWith(" (git)"):
    cleanUrl = cleanUrl[0 .. ^7]
  elif cleanUrl.endsWith(" (hg)"):
    cleanUrl = cleanUrl[0 .. ^6]

  if cleanUrl.endsWith(".git"):
    cleanUrl = cleanUrl[0 .. ^5]
  if cleanUrl.endsWith("/"):
    cleanUrl = cleanUrl[0 .. ^2]

  if "github.com" in cleanUrl:
    return cleanUrl.replace("github.com", "raw.githubusercontent.com")
  elif "codeberg.org" in cleanUrl:
    return cleanUrl & "/raw/branch"
  elif "gitlab.com" in cleanUrl:
    return cleanUrl & "/-/raw"
  elif "sr.ht" in cleanUrl:
    return cleanUrl & "/blob"
  return ""

func parseNimbleInfo*(
    raw, name, url: string, tags: seq[string]
): string {.noSideEffect.} =
  ## Parses `.nimble` file content and generates a formatted string
  ## for the details panel.
  var info = initTable[string, string]()
  var requires: seq[string] = @[]

  for line in raw.splitLines():
    let l = line.strip()
    if l.len == 0 or l.startsWith("#"):
      continue

    let lowerL = l.toLowerAscii()

    if lowerL.startsWith("requires"):
      var rest =
        if lowerL.startsWith("requires:"):
          l[9 ..^ 1].strip()
        else:
          l[8 ..^ 1].strip()
      if rest.startsWith("(") and rest.endsWith(")"):
        rest = rest[1 ..^ 2]

      for part in rest.split(','):
        let dep = part.strip().strip(chars = {'"'})
        if dep.len > 0:
          requires.add(dep)
    elif '=' in l:
      let parts = l.split('=', 1)
      let key = parts[0].strip().toLowerAscii()
      let val = parts[1].strip().strip(chars = {'"'})

      case key
      of "version":
        info["Version"] = val
      of "author":
        info["Author"] = val
      of "description":
        info["Description"] = val
      of "license":
        info["License"] = val
      else:
        discard

  result = newStringOfCap(raw.len + 200)
  result.add("Name           : " & name & "\n")
  if info.hasKey("Version"):
    result.add("Version        : " & info["Version"] & "\n")
  if info.hasKey("Author"):
    result.add("Author         : " & info["Author"] & "\n")
  if info.hasKey("Description"):
    result.add("Description    : " & info["Description"] & "\n")
  if info.hasKey("License"):
    result.add("License        : " & info["License"] & "\n")
  result.add("URL            : " & url & "\n")
  if tags.len > 0:
    result.add("Tags           : " & tags.join(", ") & "\n")

  if requires.len > 0:
    result.add("Requires       :" & "\n")
    for r in requires:
      result.add("                 - " & r & "\n")

func formatFallbackInfo*(raw: string): string {.noSideEffect.} =
  ## Formats `nimble search` output as fallback if `.nimble` file
  ## cannot be downloaded.
  var info = initTable[string, string]()
  for line in raw.splitLines():
    if line.strip().len == 0:
      continue
    if not line.startsWith(" ") and line.endsWith(":"):
      info["Name"] = line[0 ..^ 2]
    else:
      let l = line.strip()
      if ':' in l:
        let parts = l.split(':', 1)
        let key = parts[0].strip().toLowerAscii()
        let val = parts[1].strip()
        case key
        of "url":
          info["URL"] = val
        of "tags":
          info["Tags"] = val
        of "description":
          info["Description"] = val
        of "license":
          info["License"] = val
        of "version":
          info["Version"] = val
        else:
          discard

  result = newStringOfCap(raw.len + 100)
  if info.hasKey("Name"):
    result.add("Name           : " & info["Name"] & "\n")
  if info.hasKey("Version"):
    result.add("Version        : " & info["Version"] & "\n")
  if info.hasKey("Description"):
    result.add("Description    : " & info["Description"] & "\n")
  if info.hasKey("License"):
    result.add("License        : " & info["License"] & "\n")
  if info.hasKey("URL"):
    result.add("URL            : " & info["URL"] & "\n")
  if info.hasKey("Tags"):
    result.add("Tags           : " & info["Tags"] & "\n")
  result.add("\n(Info from local nimble search cache)")
