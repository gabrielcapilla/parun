import std/[os, strutils, times]

import ../src/utils/linux_statx

const Iterations = 60

proc stdMTimeUnixNs(path: string): int64 =
  let t = getLastModificationTime(path)
  t.toUnix() * 1_000_000_000'i64 + int64(t.nanosecond)

proc statxMTimeOrZero(path: string): int64 =
  when defined(linux):
    let res = statxMTimeUnixNs(path)
    if res.ok:
      return res.ns
  0'i64

proc newestStdNs(dirPath: string): int64 =
  if not dirExists(dirPath):
    return 0
  result = stdMTimeUnixNs(dirPath)
  try:
    for kind, path in walkDir(dirPath):
      if kind in {pcFile, pcDir, pcLinkToFile, pcLinkToDir}:
        let ns = stdMTimeUnixNs(path)
        if ns > result:
          result = ns
  except CatchableError:
    discard

proc newestStatxNs(dirPath: string): int64 =
  result = statxMTimeOrZero(dirPath)
  if result == 0:
    return
  try:
    for kind, path in walkDir(dirPath):
      if kind in {pcFile, pcDir, pcLinkToFile, pcLinkToDir}:
        let ns = statxMTimeOrZero(path)
        if ns > result:
          result = ns
  except CatchableError:
    discard

proc measure(label: string; iterations: int; op: proc(): int64) =
  var checksum = 0'i64
  var last = 0'i64
  let started = epochTime()
  for _ in 0 ..< iterations:
    last = op()
    checksum = checksum xor last
  let elapsedMs = (epochTime() - started) * 1000.0
  echo label,
    " iterations=", iterations,
    " total_ms=", elapsedMs.formatFloat(ffDecimal, 3),
    " avg_ms=", (elapsedMs / float(iterations)).formatFloat(ffDecimal, 3),
    " last=", last,
    " checksum=", checksum

when isMainModule:
  let dirPath =
    if paramCount() > 0:
      paramStr(1)
    else:
      "/var/lib/pacman/local"

  if not dirExists(dirPath):
    quit "missing directory: " & dirPath, 1

  let stdValue = newestStdNs(dirPath)
  let statxValue = newestStatxNs(dirPath)
  echo "parity std_ns=", stdValue, " statx_ns=", statxValue,
    " equal=", stdValue == statxValue

  measure("newest_std_mtime", Iterations, proc(): int64 = newestStdNs(dirPath))
  measure("newest_statx_mtime", Iterations, proc(): int64 = newestStatxNs(dirPath))
