import std/[os, osproc, strutils, tables, times]

import ../src/plugins/pacman

const
  DefaultIterations = 40
  PacmanIterations = 8

proc countInstalledDirs(localDbPath: string): int =
  for kind, _ in walkDir(localDbPath):
    if kind in {pcDir, pcLinkToDir}:
      result.inc

proc countDescFiles(localDbPath: string): int =
  for kind, pkgDir in walkDir(localDbPath):
    if kind in {pcDir, pcLinkToDir} and fileExists(pkgDir / "desc"):
      result.inc

proc countPacmanQ(): int =
  let output = execProcess("pacman", args = ["-Q"], options = {poUsePath})
  for line in output.splitLines:
    if line.len > 0:
      result.inc

proc measure(label: string; iterations: int; op: proc(): int) =
  var checksum = 0
  var last = 0
  let started = epochTime()
  for _ in 0 ..< iterations:
    last = op()
    checksum += last
  let elapsedMs = (epochTime() - started) * 1000.0
  let avgMs = elapsedMs / float(iterations)
  echo label,
    " iterations=", iterations,
    " total_ms=", elapsedMs.formatFloat(ffDecimal, 3),
    " avg_ms=", avgMs.formatFloat(ffDecimal, 3),
    " last=", last,
    " checksum=", checksum

when isMainModule:
  let localDbPath =
    if paramCount() > 0:
      paramStr(1)
    else:
      "/var/lib/pacman/local"

  if not dirExists(localDbPath):
    quit "missing local pacman database: " & localDbPath, 1

  measure("walk_dirs", DefaultIterations, proc(): int = countInstalledDirs(localDbPath))
  measure("walk_desc_files", DefaultIterations, proc(): int = countDescFiles(localDbPath))
  measure("parse_local_db", DefaultIterations, proc(): int =
    parseInstalledPackagesFromLocalDb(localDbPath).len
  )
  measure("pacman_q", PacmanIterations, proc(): int = countPacmanQ())
