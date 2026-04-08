## Hardware-accelerated text search with multi-architecture support.
##
## Supported backends:
## - SSE2 (x86/x64): 16 characters per cycle.
## - Scalar: Fallback for other architectures (ARM, etc.).

import std/[bitops, strutils]

# --- SIMD Backend Selection ---

when defined(amd64) or defined(sse2):
  ## SSE2 Implementation
  type SimdVector* {.importc: "__m128i", header: "emmintrin.h", bycopy.} = object
  const VectorSize* = 16

  func mm_set1_epi8*(
    a: int8
  ): SimdVector {.inline, importc: "_mm_set1_epi8", header: "emmintrin.h".}
  func mm_add_epi8*(
    a, b: SimdVector
  ): SimdVector {.inline, importc: "_mm_add_epi8", header: "emmintrin.h".}
  func mm_and_si*(
    a, b: SimdVector
  ): SimdVector {.inline, importc: "_mm_and_si128", header: "emmintrin.h".}
  func mm_cmpgt_epi8*(
    a, b: SimdVector
  ): SimdVector {.inline, importc: "_mm_cmpgt_epi8", header: "emmintrin.h".}
  func mm_loadu_si*(
    p: pointer
  ): SimdVector {.inline, importc: "_mm_loadu_si128", header: "emmintrin.h".}
  func mm_cmpeq_epi8*(
    a, b: SimdVector
  ): SimdVector {.inline, importc: "_mm_cmpeq_epi8", header: "emmintrin.h".}
  func mm_movemask_epi8*(
    a: SimdVector
  ): int32 {.inline, importc: "_mm_movemask_epi8", header: "emmintrin.h".}
else:
  ## Scalar Fallback
  type SimdVector* = object
    dummy: array[16, int8]

  const VectorSize* = 1

  func mm_set1_epi8*(a: int8): SimdVector {.inline.} =
    SimdVector(dummy: [a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a])

  func mm_add_epi8*(a, b: SimdVector): SimdVector {.inline.} =
    SimdVector()
  func mm_and_si*(a, b: SimdVector): SimdVector {.inline.} =
    SimdVector()
  func mm_cmpgt_epi8*(a, b: SimdVector): SimdVector {.inline.} =
    SimdVector()

  func mm_loadu_si*(p: pointer): SimdVector {.inline.} =
    var result: SimdVector
    let src = cast[ptr array[16, int8]](p)
    for i in 0 .. 15:
      result.dummy[i] = src[i]
    return result

  func mm_cmpeq_epi8*(a, b: SimdVector): SimdVector {.inline.} =
    var result: SimdVector
    for i in 0 .. 15:
      result.dummy[i] = if a.dummy[i] == b.dummy[i]: 0xFF'i8 else: 0x00'i8
    return result

  func mm_movemask_epi8*(a: SimdVector): int32 {.inline.} =
    result = 0
    for i in 0 .. 15:
      if (a.dummy[i] and 0x80) != 0:
        result = result or (1 shl i)

# --- Common SIMD Operations ---

func toLowerSimd*(ch: SimdVector): SimdVector {.inline.} =
  ## Converts ASCII characters to lowercase in parallel.
  when VectorSize > 1:
    let rangeLow = mm_set1_epi8(0x40)
    let rangeHigh = mm_set1_epi8(0x5B)
    let diff = mm_set1_epi8(0x20)
    let upperTest = mm_and_si(mm_cmpgt_epi8(rangeHigh, ch), mm_cmpgt_epi8(ch, rangeLow))
    let toLowerAdd = mm_and_si(upperTest, diff)
    result = mm_add_epi8(ch, toLowerAdd)
  else:
    var res: SimdVector
    for i in 0 .. 15:
      let c = ch.dummy[i]
      res.dummy[i] =
        if c in 0x40 .. 0x5A:
          (c + 0x20).int8
        else:
          c
    return res

# --- Search Context and Results ---

type SearchContext* = object
  isValid*: bool
  lowerTokens*: seq[string]
  queryLen*: int

type ResultsBuffer* = object
  indices*: array[2000, int32]
  scores*: array[2000, int]
  count*: int32

func prepareSearchContext*(query: string): SearchContext =
  let clean = query.strip()
  if clean.len == 0:
    return SearchContext(isValid: false)
  result.isValid = true
  result.lowerTokens = newSeqOfCap[string](8)
  for token in clean.splitWhitespace():
    let lower = token.toLowerAscii()
    result.lowerTokens.add(lower)
    result.queryLen += lower.len
  if result.lowerTokens.len == 0:
    result.isValid = false

# --- Search Implementations ---

func scoreTokenExact(
    startPtr: ptr char, len: int, lowerPattern: string, patternVec: SimdVector
): int =
  if lowerPattern.len > len:
    return 0
  let patternLen = lowerPattern.len
  var pos = 0
  let baseAddr = cast[int](startPtr)

  when VectorSize > 1:
    while pos <= len - VectorSize:
      let chunkAddr = cast[ptr SimdVector](baseAddr + pos)
      let textVec = toLowerSimd(mm_loadu_si(chunkAddr))
      let matches = mm_cmpeq_epi8(textVec, patternVec)
      let mask = mm_movemask_epi8(matches)

      if mask != 0:
        var currentMask = uint32(mask)
        while currentMask != 0:
          let offset = countTrailingZeroBits(currentMask)
          let matchPos = pos + offset
          if matchPos + patternLen <= len:
            var fullMatch = true
            for k in 1 ..< patternLen:
              if (cast[ptr char](baseAddr + matchPos + k)[]).toLowerAscii !=
                  lowerPattern[k]:
                fullMatch = false
                break
            if fullMatch:
              result = 100
              if matchPos == 0:
                result += 50
              elif matchPos > 0:
                let prev = cast[ptr char](baseAddr + matchPos - 1)[]
                if prev in {' ', '-', '_', '/'}:
                  result += 40
              return result
          currentMask = currentMask and not (1.uint32 shl offset)
      pos += VectorSize

  while pos <= len - patternLen:
    if (cast[ptr char](baseAddr + pos)[]).toLowerAscii == lowerPattern[0]:
      var fullMatch = true
      for k in 1 ..< patternLen:
        if (cast[ptr char](baseAddr + pos + k)[]).toLowerAscii != lowerPattern[k]:
          fullMatch = false
          break
      if fullMatch:
        result = 100
        if pos == 0:
          result += 50
        elif pos > 0:
          let prev = cast[ptr char](baseAddr + pos - 1)[]
          if prev in {' ', '-', '_', '/'}:
            result += 40
        return result
    pos += 1
  return 0

func scoreTokenFuzzy(startPtr: ptr char, len: int, pattern: string): int =
  var score = 0
  var pIdx = 0
  var tIdx = 0
  var lastMatchIdx = -1
  var consecutive = 0
  let baseAddr = cast[int](startPtr)
  while pIdx < pattern.len and tIdx < len:
    let pChar = pattern[pIdx]
    let tChar = (cast[ptr char](baseAddr + tIdx)[]).toLowerAscii
    if tChar == pChar:
      score += 10
      if lastMatchIdx != -1 and tIdx == lastMatchIdx + 1:
        consecutive += 1
        score += (5 * consecutive)
      else:
        consecutive = 0
        if lastMatchIdx != -1:
          score -= (tIdx - lastMatchIdx - 1)
      if tIdx == 0:
        score += 20
      elif tIdx > 0:
        let prev = cast[ptr char](baseAddr + tIdx - 1)[]
        if prev in {' ', '-', '_', '/'}:
          score += 15
      lastMatchIdx = tIdx
      pIdx += 1
    tIdx += 1
  if pIdx < pattern.len:
    return 0
  return max(1, score)

func scorePackageSimd*(textPtr: ptr char, len: int, ctx: SearchContext): int =
  if not ctx.isValid or len == 0:
    return 0
  var totalScore = 0
  for token in ctx.lowerTokens:
    let patternVec = mm_set1_epi8(token[0].ord.int8)
    var s = scoreTokenExact(textPtr, len, token, patternVec)
    if s == 0:
      s = scoreTokenFuzzy(textPtr, len, token)
    if s == 0:
      return 0
    totalScore += s
  let density = float(ctx.queryLen) / float(len)
  totalScore = int(float(totalScore) * (1.0 + density))
  return min(totalScore, 999)

proc countingSortResults*(buf: var ResultsBuffer) =
  if buf.count == 0:
    return
  const MaxScore = 1000
  var counts: array[MaxScore, uint16]
  for i in 0 ..< buf.count:
    inc(counts[buf.scores[i]])
  var prefixSums: array[MaxScore, uint16]
  var running: uint16 = 0
  for s in countdown(MaxScore - 1, 0):
    prefixSums[s] = running
    running += counts[s]
  var outputIndices: array[2000, int32]
  var outputScores: array[2000, int]
  for i in 0 ..< buf.count:
    let s = buf.scores[i]
    let pos = prefixSums[s]
    outputIndices[pos] = buf.indices[i]
    outputScores[pos] = buf.scores[i]
    inc(prefixSums[s])
  for i in 0 ..< buf.count:
    buf.indices[i] = outputIndices[i]
    buf.scores[i] = outputScores[i]
