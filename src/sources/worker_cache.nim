import std/hashes

const
  WorkerDetailsCacheLimit* = 32
  WorkerDetailsCacheByteBudget* = 256 * 1024
  WorkerDetailsCacheInitialBytes = 1024

type
  PackedDetailEntry = object
    valid: bool
    keyHash: uint32
    keyStart: uint32
    keyLen: uint16
    valueStart: uint32
    valueLen: uint32

  PackedDetailCache* = object
    arena: seq[char]
    arenaUsed: int
    count*: int
    nextEvict: int
    entries: array[WorkerDetailsCacheLimit, PackedDetailEntry]

proc hash32(value: string): uint32 {.inline.} =
  uint32(cast[uint](hash(value)) and 0xFFFF_FFFF'u)

proc arenaSliceToString(arena: seq[char], startPos: int, sliceLen: int): string =
  if sliceLen <= 0:
    return ""
  if startPos < 0 or startPos + sliceLen > arena.len:
    return ""
  result = newStringOfCap(sliceLen)
  result.setLen(sliceLen)
  copyMem(addr result[0], unsafeAddr arena[startPos], sliceLen)

proc arenaEq(arena: seq[char], startPos: int, sliceLen: int, value: string): bool =
  if sliceLen != value.len:
    return false
  if sliceLen == 0:
    return true
  if startPos < 0 or startPos + sliceLen > arena.len:
    return false
  equalMem(unsafeAddr arena[startPos], unsafeAddr value[0], sliceLen)

proc clearDetailsCache(cache: var PackedDetailCache) =
  cache.arenaUsed = 0
  cache.count = 0
  cache.nextEvict = 0
  for i in 0 ..< WorkerDetailsCacheLimit:
    cache.entries[i].valid = false

proc initDetailsCache*(): PackedDetailCache =
  PackedDetailCache(arena: @[], arenaUsed: 0, count: 0, nextEvict: 0)

proc findDetailsCacheSlot(cache: PackedDetailCache, key: string, h: uint32): int =
  let maxIdx = min(cache.count, WorkerDetailsCacheLimit)
  for i in 0 ..< maxIdx:
    let entry = cache.entries[i]
    if not entry.valid or entry.keyHash != h:
      continue
    if arenaEq(cache.arena, int(entry.keyStart), int(entry.keyLen), key):
      return i
  -1

proc getDetailsCache*(cache: PackedDetailCache, key: string, value: var string): bool =
  let h = hash32(key)
  let slot = findDetailsCacheSlot(cache, key, h)
  if slot < 0:
    return false
  let entry = cache.entries[slot]
  value = arenaSliceToString(cache.arena, int(entry.valueStart), int(entry.valueLen))
  true

proc putDetailsCache*(cache: var PackedDetailCache, key: string, value: string) =
  if key.len > high(uint16).int:
    return

  let needed = key.len + value.len
  if needed <= 0 or needed > cache.arena.len:
    if needed <= 0 or needed > WorkerDetailsCacheByteBudget:
      return
    if cache.arena.len == 0:
      cache.arena = newSeq[char](
        min(WorkerDetailsCacheByteBudget, max(WorkerDetailsCacheInitialBytes, needed))
      )
  if cache.arenaUsed + needed > cache.arena.len:
    clearDetailsCache(cache)
    let nextCapacity = min(
      WorkerDetailsCacheByteBudget,
      max(cache.arena.len * 2, max(WorkerDetailsCacheInitialBytes, needed)),
    )
    if nextCapacity > cache.arena.len:
      cache.arena.setLen(nextCapacity)

  let h = hash32(key)
  var slot = findDetailsCacheSlot(cache, key, h)
  if slot < 0:
    if cache.count < WorkerDetailsCacheLimit:
      slot = cache.count
      cache.count.inc()
    else:
      slot = cache.nextEvict
      cache.nextEvict = (cache.nextEvict + 1) mod WorkerDetailsCacheLimit

  let keyStart = cache.arenaUsed
  if key.len > 0:
    copyMem(addr cache.arena[keyStart], unsafeAddr key[0], key.len)
  cache.arenaUsed += key.len

  let valueStart = cache.arenaUsed
  if value.len > 0:
    copyMem(addr cache.arena[valueStart], unsafeAddr value[0], value.len)
  cache.arenaUsed += value.len

  cache.entries[slot] = PackedDetailEntry(
    valid: true,
    keyHash: h,
    keyStart: uint32(keyStart),
    keyLen: uint16(key.len),
    valueStart: uint32(valueStart),
    valueLen: uint32(value.len),
  )

proc detailsCacheBytes*(cache: PackedDetailCache): int {.inline.} =
  cache.arena.len + WorkerDetailsCacheLimit * sizeof(PackedDetailEntry)

func detailsCacheBudgetBytes*(): int {.inline.} =
  WorkerDetailsCacheByteBudget + WorkerDetailsCacheLimit * sizeof(PackedDetailEntry)
