## Linux procfs sampling helpers for runtime memory budgets.
import std/[os, strutils]

type ProcfsSample* = object
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
  var i = 0
  while i < line.len and line[i] != ':':
    inc i
  if i >= line.len:
    return 0
  inc i
  while i < line.len and line[i] <= ' ':
    inc i

  var value = 0
  var sawDigit = false
  while i < line.len and line[i] in {'0' .. '9'}:
    sawDigit = true
    value = value * 10 + (ord(line[i]) - ord('0'))
    inc i
  if sawDigit:
    return value
  0

proc readProcfsSample*(pid: int): ProcfsSample =
  ## Reads key RSS/PSS/private-dirty metrics from `/proc/<pid>`.
  result.pid = pid

  let procDir = "/proc/" & $pid
  let statusPath = procDir & "/status"
  if fileExists(statusPath):
    var gotVmRss = false
    var gotVmSize = false
    var gotRssAnon = false
    var gotRssFile = false
    for line in lines(statusPath):
      if not gotVmRss and line.startsWith("VmRSS:"):
        result.vmRssKb = parseProcKb(line)
        gotVmRss = true
      elif not gotVmSize and line.startsWith("VmSize:"):
        result.vmSizeKb = parseProcKb(line)
        gotVmSize = true
      elif not gotRssAnon and line.startsWith("RssAnon:"):
        result.rssAnonKb = parseProcKb(line)
        gotRssAnon = true
      elif not gotRssFile and line.startsWith("RssFile:"):
        result.rssFileKb = parseProcKb(line)
        gotRssFile = true
      if gotVmRss and gotVmSize and gotRssAnon and gotRssFile:
        break

  let rollupPath = procDir & "/smaps_rollup"
  if fileExists(rollupPath):
    var gotRss = false
    var gotPss = false
    var gotPrivateDirty = false
    var gotSharedClean = false
    for line in lines(rollupPath):
      if not gotRss and line.startsWith("Rss:"):
        result.rssKb = parseProcKb(line)
        gotRss = true
      elif not gotPss and line.startsWith("Pss:"):
        result.pssKb = parseProcKb(line)
        gotPss = true
      elif not gotPrivateDirty and line.startsWith("Private_Dirty:"):
        result.privateDirtyKb = parseProcKb(line)
        gotPrivateDirty = true
      elif not gotSharedClean and line.startsWith("Shared_Clean:"):
        result.sharedCleanKb = parseProcKb(line)
        gotSharedClean = true
      if gotRss and gotPss and gotPrivateDirty and gotSharedClean:
        break
