import std/[os, strutils]

type
  ProcfsSample* = object
    pid*: int
    vmRssKb*: int
    vmSizeKb*: int
    rssKb*: int
    pssKb*: int
    privateDirtyKb*: int
    sharedCleanKb*: int
    rssAnonKb*: int
    rssFileKb*: int

proc parseProcKb(line: string): int =
  let parts = line.splitWhitespace()
  if parts.len >= 2:
    try:
      return parseInt(parts[1])
    except ValueError:
      discard
  0

proc readProcfsSample*(pid: int): ProcfsSample =
  result.pid = pid

  let statusPath = "/proc/" & $pid & "/status"
  if fileExists(statusPath):
    for line in lines(statusPath):
      if line.startsWith("VmRSS:"):
        result.vmRssKb = parseProcKb(line)
      elif line.startsWith("VmSize:"):
        result.vmSizeKb = parseProcKb(line)
      elif line.startsWith("RssAnon:"):
        result.rssAnonKb = parseProcKb(line)
      elif line.startsWith("RssFile:"):
        result.rssFileKb = parseProcKb(line)

  let rollupPath = "/proc/" & $pid & "/smaps_rollup"
  if fileExists(rollupPath):
    for line in lines(rollupPath):
      if line.startsWith("Rss:"):
        result.rssKb = parseProcKb(line)
      elif line.startsWith("Pss:"):
        result.pssKb = parseProcKb(line)
      elif line.startsWith("Private_Dirty:"):
        result.privateDirtyKb = parseProcKb(line)
      elif line.startsWith("Shared_Clean:"):
        result.sharedCleanKb = parseProcKb(line)
