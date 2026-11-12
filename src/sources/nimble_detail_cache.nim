import std/[os, strutils, times]
import metadata_cache
import nimble

const
  SidecarDirName = "nimble-details"
  SidecarMagic = "PND1"
  SidecarVersion = 1'u32
  SidecarHeaderBytes = 24
  SidecarMaxEntries = 256
  SidecarMaxBytes = 8 * 1024 * 1024
  SidecarMaxPayloadBytes = 16 * 1024
  SidecarMaxAgeSeconds = 8 * 60 * 60
  HexDigits = "0123456789abcdef"

type SidecarEntry = object
  path: string
  size: int64
  modified: Time

proc sidecarDir(): string =
  result = getCachePath() / SidecarDirName
  createDir(result)

proc appendLe32(data: var string, pos: int, value: uint32) {.inline.} =
  for i in 0 ..< 4:
    data[pos + i] = char((value shr (i * 8)) and 0xff'u32)

proc appendLe64(data: var string, pos: int, value: uint64) {.inline.} =
  for i in 0 ..< 8:
    data[pos + i] = char((value shr (i * 8)) and 0xff'u64)

proc readLe32(data: string, pos: int): uint32 {.inline.} =
  for i in 0 ..< 4:
    result = result or (uint32(ord(data[pos + i])) shl (i * 8))

proc readLe64(data: string, pos: int): uint64 {.inline.} =
  for i in 0 ..< 8:
    result = result or (uint64(ord(data[pos + i])) shl (i * 8))

proc fnv1a(value: string): uint64 {.inline.} =
  result = 1469598103934665603'u64
  for ch in value:
    result = (result xor uint64(uint8(ch))) * 1099511628211'u64

proc hexDigest(value: uint64): string =
  result = newString(16)
  var remaining = value
  for i in countdown(15, 0):
    result[i] = HexDigits[int(remaining and 0x0f'u64)]
    remaining = remaining shr 4

proc cacheKey(name, repoUrl: string): string =
  let repo =
    if cacheKeyForRepo(repoUrl).len > 0:
      cacheKeyForRepo(repoUrl)
    else:
      repoUrl.strip()
  if name.len == 0 or repo.len == 0:
    return ""
  NimbleDetailFormatVersion & "\n" & name & "\n" & repo

proc cachePath(key: string): string =
  sidecarDir() / (hexDigest(fnv1a(key)) & ".detail")

proc safeRemove(path: string) =
  if not fileExists(path):
    return
  try:
    removeFile(path)
  except CatchableError:
    discard

proc validTimestamp(stored: uint64): bool =
  let now = getTime().toUnix()
  let timestamp = int64(stored)
  let age = now - timestamp
  age >= 0 and age <= SidecarMaxAgeSeconds

proc loadNimbleDetail*(name, repoUrl: string, content: var string): bool {.gcsafe.} =
  let key = cacheKey(name, repoUrl)
  if key.len == 0:
    return false

  let path = cachePath(key)
  if not fileExists(path):
    return false
  try:
    let fileSize = getFileSize(path)
    if fileSize < SidecarHeaderBytes or
        fileSize > SidecarHeaderBytes + key.len + SidecarMaxPayloadBytes:
      safeRemove(path)
      return false

    let data = readFile(path)
    if data.len < SidecarHeaderBytes or data[0 ..< 4] != SidecarMagic:
      safeRemove(path)
      return false
    if readLe32(data, 4) != SidecarVersion or not validTimestamp(readLe64(data, 8)):
      safeRemove(path)
      return false

    let keyLen = int(readLe32(data, 16))
    let payloadLen = int(readLe32(data, 20))
    if keyLen != key.len or payloadLen <= 0 or payloadLen > SidecarMaxPayloadBytes or
        SidecarHeaderBytes + keyLen + payloadLen != data.len:
      safeRemove(path)
      return false
    if data[SidecarHeaderBytes ..< SidecarHeaderBytes + keyLen] != key:
      safeRemove(path)
      return false

    content = data[SidecarHeaderBytes + keyLen ..< data.len]
    true
  except CatchableError:
    safeRemove(path)
    false

proc pruneNimbleDetails*() {.gcsafe.}

proc writeNimbleDetail*(name, repoUrl, content: string): bool {.gcsafe.} =
  if content.len == 0 or content.len > SidecarMaxPayloadBytes:
    return false
  let key = cacheKey(name, repoUrl)
  if key.len == 0 or key.len > high(uint32).int:
    return false

  let path = cachePath(key)
  var data = newString(SidecarHeaderBytes + key.len + content.len)
  for i in 0 ..< SidecarMagic.len:
    data[i] = SidecarMagic[i]
  appendLe32(data, 4, SidecarVersion)
  appendLe64(data, 8, uint64(getTime().toUnix()))
  appendLe32(data, 16, uint32(key.len))
  appendLe32(data, 20, uint32(content.len))
  copyMem(addr data[SidecarHeaderBytes], unsafeAddr key[0], key.len)
  copyMem(addr data[SidecarHeaderBytes + key.len], unsafeAddr content[0], content.len)

  let tempPath =
    path & ".tmp." & $getCurrentProcessId() & "." & $int64(epochTime() * 1000.0)
  try:
    writeFile(tempPath, data)
    moveFile(tempPath, path)
    pruneNimbleDetails()
    true
  except CatchableError:
    safeRemove(tempPath)
    false

proc pruneNimbleDetails*() {.gcsafe.} =
  let dir = sidecarDir()
  var entries = newSeqOfCap[SidecarEntry](SidecarMaxEntries)
  var totalBytes: int64 = 0
  try:
    for kind, path in walkDir(dir):
      if kind != pcFile or not path.endsWith(".detail"):
        continue
      let size = getFileSize(path)
      entries.add(
        SidecarEntry(path: path, size: size, modified: getLastModificationTime(path))
      )
      totalBytes += size
  except CatchableError:
    return

  while entries.len > SidecarMaxEntries or totalBytes > SidecarMaxBytes:
    if entries.len == 0:
      break
    var oldest = 0
    for i in 1 ..< entries.len:
      if entries[i].modified < entries[oldest].modified:
        oldest = i
    totalBytes -= entries[oldest].size
    safeRemove(entries[oldest].path)
    entries.delete(oldest)
