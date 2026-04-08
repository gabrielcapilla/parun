import std/[hashes, os, parsejson, streams, strutils]

const
  WorkerDetailsCacheLimit* = 32
  WorkerDetailsCacheBytes = 256 * 1024
  NimbleMetaMinSlots = 2048

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

  PackedNimbleMetaEntry = object
    keyHash: uint32
    nameStart: uint32
    nameLen: uint16
    urlStart: uint32
    urlLen: uint16
    tagsStart: uint32
    tagsLen: uint16

  PackedNimbleMetaCache* = object
    arena: seq[char]
    slots*: seq[int32] # -1 means empty, otherwise index into entries
    entries*: seq[PackedNimbleMetaEntry]

  PackedInstalledEntry = object
    keyHash: uint32
    nameStart: uint32
    nameLen: uint16

  PackedInstalledMap* = object
    arena: seq[char]
    slots*: seq[int32] # -1 means empty, otherwise index into entries
    entries*: seq[PackedInstalledEntry]

proc hash32(value: string): uint32 {.inline.} =
  uint32(cast[uint](hash(value)) and 0xFFFF_FFFF'u)

proc hashChars(value: openArray[char]): uint32 {.inline.} =
  ## 32-bit FNV-1a hash for string slices without allocation.
  var h = 2166136261'u32
  for ch in value:
    h = (h xor uint32(uint8(ch))) * 16777619'u32
  h

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

proc arenaEq(
    arena: seq[char], startPos: int, sliceLen: int, value: openArray[char]
): bool =
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

  if cache.arena.len == 0:
    cache.arena = newSeq[char](WorkerDetailsCacheBytes)
  let needed = key.len + value.len
  if needed <= 0 or needed > cache.arena.len:
    return
  if cache.arenaUsed + needed > cache.arena.len:
    clearDetailsCache(cache)

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

proc nextPow2AtLeast(value: int): int =
  result = 1
  while result < value:
    result = result shl 1

proc initPackedNimbleMetaCache(estimatedEntries: int = 0): PackedNimbleMetaCache =
  if estimatedEntries <= 0:
    return PackedNimbleMetaCache(arena: @[], slots: @[], entries: @[])
  let capEntries = max(estimatedEntries, 16)
  let slotCount = nextPow2AtLeast(max(NimbleMetaMinSlots, capEntries * 2))
  result.slots = newSeq[int32](slotCount)
  for i in 0 ..< slotCount:
    result.slots[i] = -1
  result.entries = newSeqOfCap[PackedNimbleMetaEntry](capEntries)
  result.arena = newSeqOfCap[char](capEntries * 48)

proc rehashNimbleMeta(cache: var PackedNimbleMetaCache, newSlotCount: int) =
  var slots = newSeq[int32](newSlotCount)
  for i in 0 ..< newSlotCount:
    slots[i] = -1
  let mask = newSlotCount - 1
  for idx in 0 ..< cache.entries.len:
    let entry = cache.entries[idx]
    var slot = int(entry.keyHash and uint32(mask))
    while slots[slot] >= 0:
      slot = (slot + 1) and mask
    slots[slot] = int32(idx)
  cache.slots = slots

proc appendArena(
    cache: var PackedNimbleMetaCache, value: string
): tuple[start: uint32, len: uint16] =
  if value.len > high(uint16).int:
    return (0'u32, 0'u16)
  let start = cache.arena.len
  if value.len > 0:
    cache.arena.setLen(start + value.len)
    copyMem(addr cache.arena[start], unsafeAddr value[0], value.len)
  (uint32(start), uint16(value.len))

proc putNimbleMeta(cache: var PackedNimbleMetaCache, name, url, tagsLine: string) =
  if name.len == 0 or name.len > high(uint16).int:
    return
  if cache.slots.len == 0:
    cache = initPackedNimbleMetaCache(512)
  if (cache.entries.len + 1) * 10 >= cache.slots.len * 7:
    rehashNimbleMeta(cache, cache.slots.len shl 1)

  let h = hash32(name)
  let mask = cache.slots.len - 1
  var slot = int(h and uint32(mask))
  while cache.slots[slot] >= 0:
    slot = (slot + 1) and mask

  let (nameStart, nameLen) = appendArena(cache, name)
  let (urlStart, urlLen) = appendArena(cache, url)
  let (tagsStart, tagsLen) = appendArena(cache, tagsLine)

  let idx = cache.entries.len
  cache.entries.add(
    PackedNimbleMetaEntry(
      keyHash: h,
      nameStart: nameStart,
      nameLen: nameLen,
      urlStart: urlStart,
      urlLen: urlLen,
      tagsStart: tagsStart,
      tagsLen: tagsLen,
    )
  )
  cache.slots[slot] = int32(idx)

proc getNimbleMeta*(
    cache: PackedNimbleMetaCache, name: string, url: var string, tagsLine: var string
): bool =
  if cache.slots.len == 0:
    return false
  let h = hash32(name)
  let mask = cache.slots.len - 1
  var slot = int(h and uint32(mask))
  var probes = 0
  while probes < cache.slots.len:
    let idx = cache.slots[slot]
    if idx < 0:
      return false
    let entry = cache.entries[int(idx)]
    if entry.keyHash == h and
        arenaEq(cache.arena, int(entry.nameStart), int(entry.nameLen), name):
      url = arenaSliceToString(cache.arena, int(entry.urlStart), int(entry.urlLen))
      tagsLine =
        arenaSliceToString(cache.arena, int(entry.tagsStart), int(entry.tagsLen))
      return true
    slot = (slot + 1) and mask
    probes.inc()
  false

proc nimbleMetaCacheBytes*(cache: PackedNimbleMetaCache): int {.inline.} =
  cache.arena.len + capacity(cache.slots) * sizeof(int32) +
    capacity(cache.entries) * sizeof(PackedNimbleMetaEntry)

proc loadPackedNimbleMeta*(jsonPath: string): PackedNimbleMetaCache =
  if not fileExists(jsonPath):
    return initPackedNimbleMetaCache()
  var estimated = 4096
  try:
    estimated = max(512, int(getFileSize(jsonPath) div 160))
  except CatchableError:
    discard
  result = initPackedNimbleMetaCache(estimated)

  let fs = newFileStream(jsonPath, fmRead)
  if fs.isNil:
    return

  var parser = JsonParser()
  try:
    parser.open(fs, jsonPath)
    var nameStr = ""
    var urlStr = ""
    var tagsLine = ""
    var inTags = false
    var currentKey = ""
    var inObject = false

    parser.next()
    while parser.kind != jsonEof:
      case parser.kind
      of jsonObjectStart:
        inObject = true
        nameStr.setLen(0)
        urlStr.setLen(0)
        tagsLine.setLen(0)
        currentKey.setLen(0)
        inTags = false
        parser.next()
      of jsonObjectEnd:
        if nameStr.len > 0:
          putNimbleMeta(result, nameStr, urlStr, tagsLine)
        inObject = false
        parser.next()
      of jsonString:
        if inObject:
          if inTags:
            if tagsLine.len > 0:
              tagsLine.add(", ")
            tagsLine.add(parser.str)
          else:
            if currentKey.len > 0:
              if currentKey.cmpIgnoreCase("name") == 0:
                nameStr = parser.str
              elif currentKey.cmpIgnoreCase("url") == 0:
                urlStr = parser.str
              currentKey.setLen(0)
            else:
              currentKey = parser.str
        parser.next()
      of jsonArrayStart:
        if currentKey.cmpIgnoreCase("tags") == 0:
          inTags = true
          currentKey.setLen(0)
        parser.next()
      of jsonArrayEnd:
        inTags = false
        parser.next()
      else:
        if parser.kind != jsonString:
          currentKey.setLen(0)
        parser.next()
    parser.close()
    fs.close()
  except CatchableError:
    try:
      parser.close()
      fs.close()
    except CatchableError:
      discard

proc initPackedInstalledMap(estimatedEntries: int = 0): PackedInstalledMap =
  if estimatedEntries <= 0:
    return PackedInstalledMap(arena: @[], slots: @[], entries: @[])
  let capEntries = max(estimatedEntries, 16)
  let slotCount = nextPow2AtLeast(capEntries * 2)
  result.slots = newSeq[int32](slotCount)
  for i in 0 ..< slotCount:
    result.slots[i] = -1
  result.entries = newSeqOfCap[PackedInstalledEntry](capEntries)
  result.arena = newSeqOfCap[char](capEntries * 20)

proc rehashInstalledMap(cache: var PackedInstalledMap, newSlotCount: int) =
  var slots = newSeq[int32](newSlotCount)
  for i in 0 ..< newSlotCount:
    slots[i] = -1
  let mask = newSlotCount - 1
  for idx in 0 ..< cache.entries.len:
    let entry = cache.entries[idx]
    var slot = int(entry.keyHash and uint32(mask))
    while slots[slot] >= 0:
      slot = (slot + 1) and mask
    slots[slot] = int32(idx)
  cache.slots = slots

proc putInstalledMap(cache: var PackedInstalledMap, name: openArray[char]) =
  if name.len == 0 or name.len > high(uint16).int:
    return
  if cache.slots.len == 0:
    cache = initPackedInstalledMap(4096)
  if (cache.entries.len + 1) * 10 >= cache.slots.len * 7:
    rehashInstalledMap(cache, cache.slots.len shl 1)

  let h = hashChars(name)
  let mask = cache.slots.len - 1
  var slot = int(h and uint32(mask))
  while cache.slots[slot] >= 0:
    let idx = int(cache.slots[slot])
    let entry = cache.entries[idx]
    if entry.keyHash == h and
        arenaEq(cache.arena, int(entry.nameStart), int(entry.nameLen), name):
      return
    slot = (slot + 1) and mask

  let nameStart = cache.arena.len
  cache.arena.setLen(nameStart + name.len)
  copyMem(addr cache.arena[nameStart], unsafeAddr name[0], name.len)
  let idx = cache.entries.len
  cache.entries.add(
    PackedInstalledEntry(
      keyHash: h, nameStart: uint32(nameStart), nameLen: uint16(name.len)
    )
  )
  cache.slots[slot] = int32(idx)

proc containsInstalledMap*(cache: PackedInstalledMap, name: openArray[char]): bool =
  if name.len == 0 or cache.slots.len == 0:
    return false
  let h = hashChars(name)
  let mask = cache.slots.len - 1
  var slot = int(h and uint32(mask))
  var probes = 0
  while probes < cache.slots.len:
    let idx = cache.slots[slot]
    if idx < 0:
      return false
    let entry = cache.entries[int(idx)]
    if entry.keyHash == h and
        arenaEq(cache.arena, int(entry.nameStart), int(entry.nameLen), name):
      return true
    slot = (slot + 1) and mask
    probes.inc()
  false

proc containsInstalledMap*(cache: PackedInstalledMap, name: string): bool {.inline.} =
  if name.len == 0:
    return false
  containsInstalledMap(cache, name.toOpenArray(0, name.high))

proc installedMapBytes*(cache: PackedInstalledMap): int {.inline.} =
  cache.arena.len + capacity(cache.slots) * sizeof(int32) +
    capacity(cache.entries) * sizeof(PackedInstalledEntry)

proc parseInstalledPackagesPacked*(output: string): PackedInstalledMap =
  let estimated = max(256, output.count('\n'))
  result = initPackedInstalledMap(estimated)
  for line in output.split('\n'):
    if line.len == 0:
      continue
    var endPos = 0
    while endPos < line.len and line[endPos] != ' ' and line[endPos] != '\t':
      endPos.inc()
    if endPos > 0:
      putInstalledMap(result, line.toOpenArray(0, endPos - 1))
