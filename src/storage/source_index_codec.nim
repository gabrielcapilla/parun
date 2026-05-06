## Low-level encoding/decoding primitives for `.prix` sections.
##
## Notes:
## - Exposes LE helpers, packed-word transforms, and cold-blob compression.
## - Runtime decode stats are tracked globally for perf snapshots.
import source_index_core

var coldDecodeStats: ColdDecodeStats

proc resetColdDecodeStats*() =
  ## Clears global decode counters.
  coldDecodeStats = default(ColdDecodeStats)

proc snapshotColdDecodeStats*(): ColdDecodeStats =
  ## Returns current decode counters snapshot.
  coldDecodeStats

proc addLe16*(dst: var string, value: uint16) =
  ## Appends a little-endian u16.
  dst.add(char(value and 0xFF))
  dst.add(char((value shr 8) and 0xFF))

proc addLe32*(dst: var string, value: uint32) =
  ## Appends a little-endian u32.
  dst.add(char(value and 0xFF))
  dst.add(char((value shr 8) and 0xFF))
  dst.add(char((value shr 16) and 0xFF))
  dst.add(char((value shr 24) and 0xFF))

proc addLe64*(dst: var string, value: uint64) =
  ## Appends a little-endian u64.
  for shift in countup(0, 56, 8):
    dst.add(char((value shr shift) and 0xFF))

proc addUint32Value*(dst: var string, value: uint32) {.inline.} =
  dst.addLe32(value)

proc readU16Bytes*(data: ptr UncheckedArray[byte], byteOffset: int): int {.inline.} =
  int(data[byteOffset]) or (int(data[byteOffset + 1]) shl 8)

proc readU32Bytes*(data: ptr UncheckedArray[byte], byteOffset: int): int {.inline.} =
  int(data[byteOffset]) or (int(data[byteOffset + 1]) shl 8) or
    (int(data[byteOffset + 2]) shl 16) or (int(data[byteOffset + 3]) shl 24)

proc readU64Bytes*(data: ptr UncheckedArray[byte], byteOffset: int): int {.inline.} =
  result = 0
  for i in 0 ..< 8:
    result = result or (int(data[byteOffset + i]) shl (8 * i))

proc readU16At*(data: ptr UncheckedArray[byte], index: int): int {.inline.} =
  int(data[index * 2]) or (int(data[index * 2 + 1]) shl 8)

proc readPackedWordAt*(
    data: ptr UncheckedArray[byte], index: int, wordBytes: int
): int {.inline.} =
  ## Reads 24-bit or 32-bit packed integer at element index.
  let base = index * wordBytes
  if wordBytes == PackedWord24Bytes:
    int(data[base]) or (int(data[base + 1]) shl 8) or (int(data[base + 2]) shl 16)
  else:
    int(data[base]) or (int(data[base + 1]) shl 8) or (int(data[base + 2]) shl 16) or
      (int(data[base + 3]) shl 24)

proc checkedU16*(value: int, label: string): uint16 =
  ## Range-check helper used during index build.
  if value < 0 or value > high(uint16).int:
    raise newException(ValueError, label & " exceeds uint16 range")
  uint16(value)

proc checkedU32*(value: int, label: string): uint32 =
  ## Range-check helper used during index build.
  if value < 0 or value > high(uint32).int:
    raise newException(ValueError, label & " exceeds uint32 range")
  uint32(value)

proc canPackWords24*(data: string): bool =
  if data.len == 0:
    return true
  if (data.len and 3) != 0:
    return false
  var i = 3
  while i < data.len:
    if uint8(data[i]) != 0'u8:
      return false
    i += 4
  true

proc packWords24*(data: string): string =
  if data.len == 0:
    return ""
  if (data.len and 3) != 0:
    raise newException(ValueError, "packed word section must be 4-byte aligned")
  result = newStringOfCap((data.len div 4) * 3)
  var i = 0
  while i < data.len:
    result.add(data[i])
    result.add(data[i + 1])
    result.add(data[i + 2])
    i += 4

proc canPackU8FromU16*(data: string): bool =
  if data.len == 0:
    return true
  if (data.len and 1) != 0:
    return false
  var i = 1
  while i < data.len:
    if uint8(data[i]) != 0'u8:
      return false
    i += 2
  true

proc packU8FromU16*(data: string): string =
  if data.len == 0:
    return ""
  if (data.len and 1) != 0:
    raise newException(ValueError, "repo index section must be 2-byte aligned")
  result = newStringOfCap(data.len div 2)
  var i = 0
  while i < data.len:
    result.add(data[i])
    i += 2

proc coldBlobCode(ch: char): int {.inline.} =
  case ch
  of '0' .. '9':
    ord(ch) - ord('0')
  of 'a' .. 'z':
    10 + ord(ch) - ord('a')
  of '.':
    36
  of '-':
    37
  of '_':
    38
  of ':':
    39
  of '+':
    40
  of '~':
    41
  of '/':
    42
  of '@':
    43
  of '=':
    44
  of ',':
    45
  of '%':
    46
  of '^':
    47
  of '&':
    48
  of '*':
    49
  of '!':
    50
  of '?':
    51
  of '#':
    52
  of '$':
    53
  of '(':
    54
  of ')':
    55
  of '[':
    56
  of ']':
    57
  of '{':
    58
  of '}':
    59
  of '<':
    60
  of '>':
    61
  of '|':
    62
  else:
    -1

proc coldBlobChar(code: int): char {.inline.} =
  case code
  of 0 .. 9:
    char(ord('0') + code)
  of 10 .. 35:
    char(ord('a') + (code - 10))
  of 36:
    '.'
  of 37:
    '-'
  of 38:
    '_'
  of 39:
    ':'
  of 40:
    '+'
  of 41:
    '~'
  of 42:
    '/'
  of 43:
    '@'
  of 44:
    '='
  of 45:
    ','
  of 46:
    '%'
  of 47:
    '^'
  of 48:
    '&'
  of 49:
    '*'
  of 50:
    '!'
  of 51:
    '?'
  of 52:
    '#'
  of 53:
    '$'
  of 54:
    '('
  of 55:
    ')'
  of 56:
    '['
  of 57:
    ']'
  of 58:
    '{'
  of 59:
    '}'
  of 60:
    '<'
  of 61:
    '>'
  of 62:
    '|'
  else:
    '\x00'

proc emitBits(
    dst: var string, bitBuf: var uint64, bitCount: var int, value: int, bits: int
) {.inline.} =
  bitBuf = bitBuf or (uint64(value and ((1 shl bits) - 1)) shl bitCount)
  bitCount += bits
  while bitCount >= 8:
    dst.add(char(bitBuf and 0xFF))
    bitBuf = bitBuf shr 8
    bitCount -= 8

proc pullBits(
    src: ptr UncheckedArray[byte],
    srcPos: var int,
    srcEnd: int,
    bitBuf: var uint64,
    bitCount: var int,
    bits: int,
): int {.inline.} =
  while bitCount < bits and srcPos < srcEnd:
    bitBuf = bitBuf or (uint64(src[srcPos]) shl bitCount)
    srcPos.inc()
    bitCount += 8
  if bitCount < bits:
    return -1
  let mask = (1'u64 shl bits) - 1'u64
  result = int(bitBuf and mask)
  bitBuf = bitBuf shr bits
  bitCount -= bits

proc encodeBlobRleBlock(
    src: string, startPos: int, blockLen: int, dst: var string
): int =
  let before = dst.len
  var bitBuf = 0'u64
  var bitCount = 0
  for i in 0 ..< blockLen:
    let ch = src[startPos + i]
    let code = coldBlobCode(ch)
    if code >= 0:
      emitBits(dst, bitBuf, bitCount, code, 6)
    else:
      emitBits(dst, bitBuf, bitCount, 63, 6)
      emitBits(dst, bitBuf, bitCount, ord(ch), 8)
  if bitCount > 0:
    dst.add(char(bitBuf and 0xFF))
  dst.len - before

proc encodeColdBlob*(raw: string): string =
  ## Encodes cold blob into block-indexed container.
  let blockCount = (raw.len + ColdBlobBlockBytes - 1) div ColdBlobBlockBytes
  var payload = newStringOfCap(
    raw.len + (if blockCount > 0: blockCount * ColdBlobBlockHeaderBytes
    else: 0)
  )
  var blockOffsets = newSeq[int](blockCount + 1)
  var encodedBlock = newStringOfCap(ColdBlobBlockBytes * 2)
  var rawPos = 0
  for blockIdx in 0 ..< blockCount:
    blockOffsets[blockIdx] = payload.len
    let rawLen = min(ColdBlobBlockBytes, raw.len - rawPos)
    encodedBlock.setLen(0)
    discard encodeBlobRleBlock(raw, rawPos, rawLen, encodedBlock)
    payload.addLe16(checkedU16(rawLen, "cold blob block raw len"))
    if encodedBlock.len < rawLen:
      payload.addLe16(checkedU16(encodedBlock.len, "cold blob block encoded len"))
      payload.add(encodedBlock)
    else:
      payload.addLe16(0'u16)
      var i = 0
      while i < rawLen:
        payload.add(raw[rawPos + i])
        i.inc()
    rawPos += rawLen
  blockOffsets[blockCount] = payload.len

  result = newStringOfCap(
    ColdBlobHeaderBytes + ((blockCount + 1) * PackedWord32Bytes) + payload.len
  )
  result.addLe32(checkedU32(raw.len, "cold blob raw len"))
  result.addLe32(uint32(ColdBlobBlockBytes))
  result.addLe32(checkedU32(blockCount, "cold blob block count"))
  for rel in blockOffsets:
    result.addLe32(checkedU32(rel, "cold blob block offset"))
  result.add(payload)

proc decodeBlobRleBlock(
    src: ptr UncheckedArray[byte],
    srcStart: int,
    srcLen: int,
    expectedLen: int,
    dst: var string,
) =
  dst.setLen(0)
  if srcLen <= 0 or expectedLen <= 0:
    return
  dst = newStringOfCap(expectedLen)
  var srcPos = srcStart
  let srcEnd = srcStart + srcLen
  var bitBuf = 0'u64
  var bitCount = 0
  while dst.len < expectedLen:
    let code = pullBits(src, srcPos, srcEnd, bitBuf, bitCount, 6)
    if code < 0:
      break
    if code == 63:
      let raw = pullBits(src, srcPos, srcEnd, bitBuf, bitCount, 8)
      if raw < 0:
        break
      dst.add(char(raw))
      continue
    let mapped = coldBlobChar(code)
    if mapped == '\x00':
      break
    dst.add(mapped)

proc initCompressedBlobMeta*(
    view: ptr SourceIndexView, section: SourceSectionId, enabled: bool
): CompressedBlobMeta =
  ## Parses compressed section header and prepares decode metadata.
  result.enabled = enabled
  result.ringNext = 0
  if not enabled:
    return
  let sectionRange = view[].sections[section]
  let sectionSize = sectionRange.size
  if sectionSize < ColdBlobHeaderBytes + PackedWord32Bytes:
    raise newException(IOError, "compressed cold blob header is truncated")
  let data =
    cast[ptr UncheckedArray[byte]](cast[int](view[].file.mem) + sectionRange.offset)
  result.rawLen = readU32Bytes(data, 0)
  result.blockBytes = readU32Bytes(data, 4)
  result.blockCount = readU32Bytes(data, 8)
  if result.blockBytes <= 0:
    raise newException(IOError, "invalid compressed cold blob block size")
  let expectedBlocks =
    if result.rawLen <= 0:
      0
    else:
      (result.rawLen + result.blockBytes - 1) div result.blockBytes
  if result.blockCount != expectedBlocks:
    raise newException(IOError, "compressed cold blob block count mismatch")
  result.offsetsStart = ColdBlobHeaderBytes
  result.payloadStart =
    result.offsetsStart + (result.blockCount + 1) * PackedWord32Bytes
  if result.payloadStart > sectionSize:
    raise newException(IOError, "compressed cold blob payload escapes section")

proc findDecodedColdBlobBlock(meta: CompressedBlobMeta, blockIdx: int): int {.inline.} =
  if meta.ring.len == 0:
    return -1
  let needle = int32(blockIdx)
  for i in 0 ..< meta.ring.len:
    let entry = meta.ring[i]
    if entry.valid and entry.blockIdx == needle:
      return i
  -1

proc validateCompressedBlobSection*(
    data: ptr UncheckedArray[byte], size: int, sectionName: string
): string =
  ## Validates compressed blob section structure.
  ## Returns `""` on success, otherwise an explanatory error string.
  if size < ColdBlobHeaderBytes + PackedWord32Bytes:
    return "compressed section header truncated: " & sectionName
  let rawLen = readU32Bytes(data, 0)
  let blockBytes = readU32Bytes(data, 4)
  let blockCount = readU32Bytes(data, 8)
  if blockBytes <= 0:
    return "invalid compressed block size in section: " & sectionName
  let expectedBlocks =
    if rawLen <= 0:
      0
    else:
      (rawLen + blockBytes - 1) div blockBytes
  if blockCount != expectedBlocks:
    return "compressed block count mismatch in section: " & sectionName
  let offsetsStart = ColdBlobHeaderBytes
  let payloadStart = offsetsStart + (blockCount + 1) * PackedWord32Bytes
  if payloadStart > size:
    return "compressed payload escapes section bounds: " & sectionName

  var prevRel = -1
  var decodedTotal = 0
  for blockIdx in 0 .. blockCount:
    let rel = readU32Bytes(data, offsetsStart + blockIdx * PackedWord32Bytes)
    if rel < 0 or rel > size - payloadStart:
      return "compressed block offset out of range in section: " & sectionName
    if rel < prevRel:
      return "compressed block offsets are not monotonic: " & sectionName
    prevRel = rel

  for blockIdx in 0 ..< blockCount:
    let relStart = readU32Bytes(data, offsetsStart + blockIdx * PackedWord32Bytes)
    let relEnd = readU32Bytes(data, offsetsStart + (blockIdx + 1) * PackedWord32Bytes)
    let blockStart = payloadStart + relStart
    let blockEnd = payloadStart + relEnd
    if blockEnd - blockStart < ColdBlobBlockHeaderBytes:
      return "compressed block header truncated in section: " & sectionName
    let rawBlockLen = readU16Bytes(data, blockStart)
    let encBlockLen = readU16Bytes(data, blockStart + 2)
    if rawBlockLen <= 0 or rawBlockLen > blockBytes:
      return "compressed block raw length invalid in section: " & sectionName
    let payloadLen = blockEnd - blockStart - ColdBlobBlockHeaderBytes
    if encBlockLen == 0:
      if payloadLen != rawBlockLen:
        return "raw compressed block payload mismatch in section: " & sectionName
    elif payloadLen != encBlockLen:
      return "encoded compressed block payload mismatch in section: " & sectionName
    decodedTotal += rawBlockLen

  if decodedTotal != rawLen:
    return "compressed section decoded size mismatch: " & sectionName
  ""

proc decodeCompressedBlobBlock*(
    view: ptr SourceIndexView,
    section: SourceSectionId,
    meta: var CompressedBlobMeta,
    blockIdx: int,
    decoded: var string,
    rawLen: var int,
): bool =
  ## Decodes one compressed block and caches it in decode ring.
  coldDecodeStats.requests.inc()
  if blockIdx < 0 or blockIdx >= meta.blockCount:
    return false
  let ringHit = findDecodedColdBlobBlock(meta, blockIdx)
  if ringHit >= 0:
    coldDecodeStats.hits.inc()
    let entry = meta.ring[ringHit]
    decoded = entry.data
    rawLen = int(entry.rawLen)
    return true
  coldDecodeStats.misses.inc()

  let sectionRange = view[].sections[section]
  let data =
    cast[ptr UncheckedArray[byte]](cast[int](view[].file.mem) + sectionRange.offset)
  let sectionLen = sectionRange.size
  let relStart = readU32Bytes(data, meta.offsetsStart + blockIdx * PackedWord32Bytes)
  let relEnd =
    readU32Bytes(data, meta.offsetsStart + (blockIdx + 1) * PackedWord32Bytes)
  let blockStart = meta.payloadStart + relStart
  let blockEnd = meta.payloadStart + relEnd
  if blockStart < 0 or blockEnd > sectionLen or
      blockEnd - blockStart < ColdBlobBlockHeaderBytes:
    return false

  let rawBlockLen = readU16Bytes(data, blockStart)
  let encBlockLen = readU16Bytes(data, blockStart + 2)
  let payloadStart = blockStart + ColdBlobBlockHeaderBytes
  if rawBlockLen <= 0:
    return false

  var blockData = ""
  blockData.setLen(rawBlockLen)
  if encBlockLen == 0:
    if payloadStart + rawBlockLen > sectionLen:
      return false
    copyMem(addr blockData[0], addr data[payloadStart], rawBlockLen)
  else:
    if payloadStart + encBlockLen > sectionLen:
      return false
    decodeBlobRleBlock(data, payloadStart, encBlockLen, rawBlockLen, blockData)
    if blockData.len != rawBlockLen:
      return false

  if meta.ring.len == 0:
    meta.ring = newSeq[DecodedColdBlobBlock](ColdBlobDecodeRingSize)
  let slot = meta.ringNext
  meta.ring[slot] = DecodedColdBlobBlock(
    valid: true, blockIdx: int32(blockIdx), rawLen: uint16(rawBlockLen), data: blockData
  )
  meta.ringNext = (meta.ringNext + 1) mod meta.ring.len
  decoded = blockData
  rawLen = rawBlockLen
  coldDecodeStats.decodedBlocks.inc()
  coldDecodeStats.decodedBytes += uint64(rawBlockLen)
  true

proc appendCompressedBlobSlice*(
    view: ptr SourceIndexView,
    section: SourceSectionId,
    meta: var CompressedBlobMeta,
    rawOffset: int,
    rawLen: int,
    buffer: var string,
    maxLen: int,
) =
  ## Appends logical raw slice from compressed blob into caller buffer.
  if rawLen <= 0:
    return
  if rawOffset < 0 or rawOffset >= meta.rawLen:
    return
  var copyLen = rawLen
  if maxLen >= 0 and maxLen < copyLen:
    copyLen = maxLen
  if copyLen <= 0:
    return
  let maxAvailable = meta.rawLen - rawOffset
  if copyLen > maxAvailable:
    copyLen = maxAvailable
  if copyLen <= 0:
    return

  var remaining = copyLen
  var cursor = rawOffset
  while remaining > 0:
    let blockIdx = cursor div meta.blockBytes
    let inBlock = cursor mod meta.blockBytes
    var blockData = ""
    var blockRawLen = 0
    if not decodeCompressedBlobBlock(
      view, section, meta, blockIdx, blockData, blockRawLen
    ):
      break
    if blockRawLen <= inBlock:
      break
    let chunk = min(remaining, blockRawLen - inBlock)
    if chunk <= 0:
      break
    let before = buffer.len
    buffer.setLen(before + chunk)
    copyMem(addr buffer[before], unsafeAddr blockData[inBlock], chunk)
    cursor += chunk
    remaining -= chunk
