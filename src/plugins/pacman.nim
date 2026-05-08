## Parsing helpers for pacman textual outputs.
import std/[os, strutils, tables]

func parseInstalledPackages*(output: string): Table[string, bool] =
  ## Builds a set-like table from `pacman -Q` output.
  result = initTable[string, bool](512)
  for line in output.split('\n'):
    if line.len == 0:
      continue
    var first = ""
    var i = 0
    for part in line.split(' '):
      if part.len == 0:
        continue
      if i == 0:
        first = part
      i.inc()
      if i > 0:
        break
    if first.len > 0:
      result[first] = true

func isPackageInstalled*(line: string): bool =
  ## Detects installed marker in repository listing output.
  return line.contains("[installed]") or line.contains("[instalado]")

proc parseInstalledPackagesFromLocalDb*(
    localDbPath: string = "/var/lib/pacman/local"
): Table[string, bool] =
  ## Builds an installed-package set directly from pacman's local database.
  ##
  ## Each installed package has a `desc` file containing a `%NAME%` marker
  ## followed by the package name. Entries without a readable name are skipped
  ## so callers can fall back to `pacman -Q` when the database is unavailable or
  ## unexpectedly malformed.
  result = initTable[string, bool](2048)
  if not dirExists(localDbPath):
    return

  for kind, pkgDir in walkDir(localDbPath):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    let descPath = pkgDir / "desc"
    if not fileExists(descPath):
      continue

    var wantName = false
    try:
      for rawLine in lines(descPath):
        let line = rawLine.strip()
        if wantName:
          if line.len > 0:
            result[line] = true
            break
        elif line == "%NAME%":
          wantName = true
    except CatchableError:
      discard
