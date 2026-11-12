import std/[os, tables]

func parseInstalledPackages*(output: string): Table[string, bool] =
  result = initTable[string, bool](512)
  var lineStart = 0
  while lineStart < output.len:
    var lineEnd = lineStart
    while lineEnd < output.len and output[lineEnd] != '\n':
      inc lineEnd

    var nameStart = lineStart
    while nameStart < lineEnd and output[nameStart] == ' ':
      inc nameStart
    var nameEnd = nameStart
    while nameEnd < lineEnd and output[nameEnd] != ' ':
      inc nameEnd
    if nameStart < nameEnd:
      result[output[nameStart ..< nameEnd]] = true

    lineStart = lineEnd + 1

proc parseInstalledPackagesFromLocalDb*(
    localDbPath: string = "/var/lib/pacman/local"
): Table[string, bool] =
  result = initTable[string, bool](2048)
  if not dirExists(localDbPath):
    return

  for kind, pkgDir in walkDir(localDbPath):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let descPath = pkgDir / "desc"

    var wantName = false
    try:
      for line in lines(descPath):
        if wantName:
          if line.len > 0:
            result[line] = true
            break
        elif line == "%NAME%":
          wantName = true
    except CatchableError:
      discard
