## UI-side details cache with bounded memory and lightweight block compression.
##
## Notes:
## - This cache stores *cold* package detail payloads keyed by package index.
## - Entries are bounded by `DetailsCacheLimit` and `DetailsCacheByteBudget`.
## - Payloads are encoded in fixed-size blocks with a tiny RLE dialect:
##   literal blocks are stored raw; repeated runs are compressed opportunistically.
import types

## Initializes an empty details cache.
proc initDetailCache*(): DetailCache =
  DetailCache(arena: @[], arenaUsed: 0, count: 0, nextEvict: 0)

## Number of active metadata entries.
func detailCacheLen*(cache: DetailCache): int {.inline, noSideEffect.} =
  cache.count

## Total allocated bytes in the payload arena.
func detailCacheCapacityBytes*(cache: DetailCache): int {.inline, noSideEffect.} =
  cache.arena.len

## Bytes currently consumed by encoded payload data.
func detailCacheUsedBytes*(cache: DetailCache): int {.inline, noSideEffect.} =
  cache.arenaUsed

## Drops all entries while retaining arena allocation for reuse.
proc clearDetailCache*(cache: var DetailCache) =
  cache.arenaUsed = 0
  cache.count = 0
  cache.nextEvict = 0
  for i in 0 ..< DetailsCacheLimit:
    cache.entries[i].valid = false

proc findDetailCacheEntry(cache: DetailCache, key: int32): int {.inline.} =
  let maxIdx = min(cache.count, DetailsCacheLimit)
  for i in 0 ..< maxIdx:
    let entry = cache.entries[i]
    if entry.valid and entry.key == key:
      return i
  -1

proc detailCacheHas*(cache: DetailCache, key: int32): bool {.inline.} =
  findDetailCacheEntry(cache, key) >= 0

proc addLe16(dst: var seq[char], value: int) {.inline.} =
  dst.add(char(value and 0xFF))
  dst.add(char((value shr 8) and 0xFF))

proc readLe16(src: seq[char], pos: int): int {.inline.} =
  int(uint8(src[pos])) or (int(uint8(src[pos + 1])) shl 8)

proc encodeDetailRleBlock(
    src: string, startPos: int, blockLen: int, dst: var seq[char]
): int =
  ## Encodes one block.
  ## Format:
  ## - literal byte: byte itself
  ## - escaped literal 0xFF: 0xFF 0x00
  ## - run: 0xFF <len> <byte>   (only when len >= 4)
  let before = dst.len
  var i = 0
  while i < blockLen:
    let ch = src[startPos + i]
    var runLen = 1
    while i + runLen < blockLen and runLen < 255 and src[startPos + i + runLen] == ch:
      runLen.inc()

    if runLen >= 4:
      dst.add(char(0xFF))
      dst.add(char(runLen))
      dst.add(ch)
      i += runLen
      continue

    if ch == char(0xFF):
      dst.add(char(0xFF))
      dst.add(char(0))
    else:
      dst.add(ch)
    i.inc()
  dst.len - before

proc decodeDetailRleBlock(
    src: seq[char], srcStart: int, srcLen: int, dst: var string, dstPos: var int
) =
  var i = 0
  while i < srcLen:
    let b = src[srcStart + i]
    if b != char(0xFF):
      if dstPos < dst.len:
        dst[dstPos] = b
      dstPos.inc()
      i.inc()
      continue

    if i + 1 >= srcLen:
      break
    let runLen = int(uint8(src[srcStart + i + 1]))
    if runLen == 0:
      if dstPos < dst.len:
        dst[dstPos] = char(0xFF)
      dstPos.inc()
      i += 2
      continue

    if i + 2 >= srcLen:
      break
    let runCh = src[srcStart + i + 2]
    for _ in 0 ..< runLen:
      if dstPos < dst.len:
        dst[dstPos] = runCh
      dstPos.inc()
    i += 3

proc encodeDetailPayload(value: string): seq[char] =
  if value.len == 0:
    return @[]

  result = newSeqOfCap[char](value.len + (value.len div DetailCacheBlockBytes + 1) * 4)
  var blockBuf = newSeqOfCap[char](DetailCacheBlockBytes * 2)
  var pos = 0
  while pos < value.len:
    let rawLen = min(DetailCacheBlockBytes, value.len - pos)
    blockBuf.setLen(0)
    discard encodeDetailRleBlock(value, pos, rawLen, blockBuf)
    if blockBuf.len < rawLen:
      result.addLe16(rawLen)
      result.addLe16(blockBuf.len)
      for ch in blockBuf:
        result.add(ch)
    else:
      result.addLe16(rawLen)
      result.addLe16(0)
      for i in 0 ..< rawLen:
        result.add(value[pos + i])
    pos += rawLen

proc detailCacheGet*(cache: DetailCache, key: int32): string =
  ## Returns decoded details for `key`, or `""` when missing/corrupt.
  let idx = findDetailCacheEntry(cache, key)
  if idx < 0:
    return ""
  let entry = cache.entries[idx]
  if not entry.valid:
    return ""
  let start = int(entry.start)
  let encodedLen = int(entry.encodedLen)
  let rawLen = int(entry.rawLen)
  if rawLen <= 0:
    return ""
  if start < 0 or start + encodedLen > cache.arena.len:
    return ""
  result = newString(rawLen)
  var srcPos = start
  var dstPos = 0
  let srcEnd = start + encodedLen
  while srcPos + 4 <= srcEnd and dstPos < rawLen:
    let blockRawLen = readLe16(cache.arena, srcPos)
    let blockEncLen = readLe16(cache.arena, srcPos + 2)
    srcPos += 4
    if blockRawLen <= 0:
      break
    if blockEncLen == 0:
      if srcPos + blockRawLen > srcEnd:
        break
      for i in 0 ..< blockRawLen:
        if dstPos < result.len:
          result[dstPos] = cache.arena[srcPos + i]
        dstPos.inc()
      srcPos += blockRawLen
    else:
      if srcPos + blockEncLen > srcEnd:
        break
      decodeDetailRleBlock(cache.arena, srcPos, blockEncLen, result, dstPos)
      srcPos += blockEncLen

proc detailCachePut*(cache: var DetailCache, key: int32, value: string) =
  ## Inserts/replaces `key` with compressed payload.
  ##
  ## Replacement policy:
  ## - update existing slot if key exists
  ## - append until fixed slot budget is exhausted
  ## - then round-robin eviction (`nextEvict`)
  let rawLen = value.len
  if rawLen < 0 or rawLen > DetailsCacheByteBudget:
    return
  let encoded = encodeDetailPayload(value)
  let encodedLen = encoded.len
  if cache.arena.len == 0:
    cache.arena = newSeq[char](DetailsCacheByteBudget)

  if cache.arenaUsed + encodedLen > cache.arena.len:
    cache.arenaUsed = 0
    cache.count = 0
    cache.nextEvict = 0
    for i in 0 ..< DetailsCacheLimit:
      cache.entries[i].valid = false

  var slot = findDetailCacheEntry(cache, key)
  if slot < 0:
    if cache.count < DetailsCacheLimit:
      slot = cache.count
      cache.count.inc()
    else:
      slot = cache.nextEvict
      cache.nextEvict = (cache.nextEvict + 1) mod DetailsCacheLimit

  if encodedLen > 0:
    copyMem(addr cache.arena[cache.arenaUsed], unsafeAddr encoded[0], encodedLen)

  cache.entries[slot] = DetailCacheEntry(
    key: key,
    start: uint32(cache.arenaUsed),
    encodedLen: uint16(encodedLen),
    rawLen: uint16(rawLen),
    valid: true,
  )
  cache.arenaUsed += encodedLen
