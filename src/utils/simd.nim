## Hardware-accelerated text search using SSE2 instructions with scalar fallback.
##
## When SSE2 is available: Processes 16 characters simultaneously per CPU cycle.
## When SSE2 is not available: Falls back to scalar character-by-character.
##
## Performance (SSE2): Approx. 16x faster than scalar comparison.
## Performance (Scalar): Same as standard character-by-character search.

import std/[bitops, strutils]
import ../core/types

when defined(amd64) or (defined(i386) and defined(sse2)):
  ## SSE2 Implementation (x86/x64 with SSE2 support)
  ##
  ## Uses compiler intrinsics for SSE2 instructions.
  ## Headers: GCC/Clang use <emmintrin.h>
  type M128i* {.importc: "__m128i", header: "emmintrin.h", bycopy.} = object

  func mm_set1_epi8*(
    a: int8
  ): M128i {.inline, importc: "_mm_set1_epi8", header: "emmintrin.h".}

  func mm_add_epi8*(
    a, b: M128i
  ): M128i {.inline, importc: "_mm_add_epi8", header: "emmintrin.h".}

  func mm_and_si128*(
    a, b: M128i
  ): M128i {.inline, importc: "_mm_and_si128", header: "emmintrin.h".}

  func mm_cmpgt_epi8*(
    a, b: M128i
  ): M128i {.inline, importc: "_mm_cmpgt_epi8", header: "emmintrin.h".}

  func mm_loadu_si128*(
    p: pointer
  ): M128i {.inline, importc: "_mm_loadu_si128", header: "emmintrin.h".}

  func mm_cmpeq_epi8*(
    a, b: M128i
  ): M128i {.inline, importc: "_mm_cmpeq_epi8", header: "emmintrin.h".}

  func mm_movemask_epi8*(
    a: M128i
  ): int32 {.inline, importc: "_mm_movemask_epi8", header: "emmintrin.h".}

  const VectorSize* = 16

  func toLowerSimd*(ch: M128i): M128i {.inline.} =
    ## Converts 16 ASCII characters to lowercase in parallel.
    ##
    ## Algorithm:
    ## 1. Identifies characters in range 'A'..'Z'.
    ## 2. Adds 0x20 to those characters (flip bit 5).
    ## 3. Leaves the rest untouched.
    let rangeLow = mm_set1_epi8(0x40)
    let rangeHigh = mm_set1_epi8(0x5B)
    let diff = mm_set1_epi8(0x20)

    let upperTest =
      mm_and_si128(mm_cmpgt_epi8(rangeHigh, ch), mm_cmpgt_epi8(ch, rangeLow))
    let toLowerAdd = mm_and_si128(upperTest, diff)
    result = mm_add_epi8(ch, toLowerAdd)
else:
  ## Scalar Fallback Implementation
  ##
  ## Used on systems without SSE2 support or non-x86 architectures (ARM, etc.).
  ## Provides same functionality but with character-by-character processing.
  type M128i* = object ## Dummy type for API compatibility
    dummy: array[16, int8]

  func mm_set1_epi8*(a: int8): M128i {.inline.} =
    ## Broadcast single byte to all 16 positions (scalar equivalent).
    M128i(dummy: [a, a, a, a, a, a, a, a, a, a, a, a, a, a, a, a])

  func mm_add_epi8*(a, b: M128i): M128i {.inline.} =
    ## Not used in scalar path - placeholder for API compatibility
    M128i()

  func mm_and_si128*(a, b: M128i): M128i {.inline.} =
    ## Not used in scalar path - placeholder for API compatibility
    M128i()

  func mm_cmpgt_epi8*(a, b: M128i): M128i {.inline.} =
    ## Not used in scalar path - placeholder for API compatibility
    M128i()

  func mm_loadu_si128*(p: pointer): M128i {.inline.} =
    ## Load up to 16 bytes (scalar equivalent).
    var result: M128i
    let src = cast[ptr array[16, int8]](p)
    for i in 0 .. 15:
      result.dummy[i] = src[i]
    return result

  func mm_cmpeq_epi8*(a, b: M128i): M128i {.inline.} =
    ## Compare 16 bytes for equality (scalar equivalent).
    var result: M128i
    for i in 0 .. 15:
      if a.dummy[i] == b.dummy[i]:
        result.dummy[i] = 0xFF'i8 # All bits set = true
      else:
        result.dummy[i] = 0x00'i8 # All bits clear = false
    return result

  func mm_movemask_epi8*(a: M128i): int32 {.inline.} =
    ## Create mask from sign bits (scalar equivalent).
    ## Each byte's MSB becomes a bit in the result.
    result = 0
    for i in 0 .. 15:
      if (a.dummy[i] and 0x80) != 0:
        result = result or (1 shl i)
    return result

  const VectorSize* = 1 # Scalar processes 1 char at a time

  func toLowerSimd*(ch: M128i): M128i {.inline.} =
    ## Convert ASCII to lowercase (scalar equivalent).
    var result: M128i
    for i in 0 .. 15:
      let c = ch.dummy[i]
      if c in 0x40 .. 0x5A: # 'A'..'Z'
        result.dummy[i] = (c + 0x20).int8
      else:
        result.dummy[i] = c
    return result

## Common types and functions (shared by SSE2 and scalar paths)

type SearchContext* = object
  ## Pre-calculated context for a search query.
  ##
  ## Avoids recalculating lowercase conversions or character vectors
  ## for every iterated package.
  isValid*: bool
  ## Individual query words.
  tokens*: seq[string]
  ## Lowercase versions (scalar fallback).
  lowerTokens*: seq[string]
  ## SIMD vectors with the first char of each token broadcasted.
  firstCharVecs*: seq[M128i]
  ## Total query length (sum of all tokens) for density calculation.
  queryLen*: int

func prepareSearchContext*(query: string): SearchContext =
  ## Prepares the search context for a new query.
  ##
  ## Generates broadcast vectors for the first character of each token,
  ## allowing a "fast filter" phase before full verification.
  let clean = query.strip()
  if clean.len == 0:
    return SearchContext(isValid: false)

  result.isValid = true
  result.tokens = clean.splitWhitespace()
  result.lowerTokens = newSeq[string](result.tokens.len)
  result.firstCharVecs = newSeq[M128i](result.tokens.len)

  for i, token in result.tokens:
    if token.len > 0:
      result.lowerTokens[i] = token.toLowerAscii()
      result.firstCharVecs[i] = mm_set1_epi8(token[0].toLowerAscii.ord.int8)
      result.queryLen += token.len

when defined(amd64) or (defined(i386) and defined(sse2)):
  ## SSE2 exact search implementation
  func scoreTokenExact(
      startPtr: ptr char, len: int, pattern: string, patternVec: M128i
  ): int =
    ## Searches for an exact substring using SIMD.
    ##
    ## Strategy:
    ## 1. Loads 16 bytes of text.
    ## 2. Compares all against the first char of the pattern (patternVec).
    ## 3. If match found (mask != 0), verifies the rest of the pattern scalarly.
    if pattern.len > len:
      return 0

    let patternLen = pattern.len
    var pos = 0
    let baseAddr = cast[int](startPtr)

    while pos <= len - VectorSize:
      let chunkAddr = cast[ptr M128i](baseAddr + pos)
      let textVec = toLowerSimd(mm_loadu_si128(chunkAddr))
      let matches = mm_cmpeq_epi8(textVec, patternVec)
      let mask = mm_movemask_epi8(matches)

      if mask != 0:
        var currentMask = uint16(mask)
        while currentMask != 0:
          let offset = countTrailingZeroBits(currentMask)
          let matchPos = pos + offset

          if matchPos + patternLen <= len:
            var fullMatch = true
            for k in 1 ..< patternLen:
              let cText = (cast[ptr char](baseAddr + matchPos + k)[]).toLowerAscii
              let cPat = pattern[k].toLowerAscii
              if cText != cPat:
                fullMatch = false
                break

            if fullMatch:
              var localScore = 100
              if matchPos == 0:
                localScore += 50
              elif matchPos > 0:
                let prev = cast[ptr char](baseAddr + matchPos - 1)[]
                if prev in {' ', '-', '_', '/'}:
                  localScore += 40

              return localScore

          currentMask = currentMask and not (1.uint16 shl offset)
      pos += VectorSize

    # Scalar fallback for the end of the string
    while pos <= len - patternLen:
      let c = (cast[ptr char](baseAddr + pos)[]).toLowerAscii
      if c == pattern[0].toLowerAscii:
        var fullMatch = true
        for k in 1 ..< patternLen:
          if (cast[ptr char](baseAddr + pos + k)[]).toLowerAscii !=
              pattern[k].toLowerAscii:
            fullMatch = false
            break
        if fullMatch:
          var localScore = 100
          if pos == 0:
            localScore += 50
          elif pos > 0:
            let prev = cast[ptr char](baseAddr + pos - 1)[]
            if prev in {' ', '-', '_'}:
              localScore += 40
          return localScore
      pos += 1
    return 0
else:
  ## Scalar exact search implementation (fallback)
  func scoreTokenExact(
      startPtr: ptr char, len: int, pattern: string, patternVec: M128i
  ): int =
    ## Searches for an exact substring using scalar comparison.
    ##
    ## patternVec is ignored in scalar path.
    if pattern.len > len:
      return 0

    let patternLen = pattern.len
    let baseAddr = cast[int](startPtr)

    for pos in 0 .. (len - patternLen):
      var fullMatch = true
      for k in 0 ..< patternLen:
        let cText = (cast[ptr char](baseAddr + pos + k)[]).toLowerAscii
        let cPat = pattern[k].toLowerAscii
        if cText != cPat:
          fullMatch = false
          break

      if fullMatch:
        var localScore = 100
        if pos == 0:
          localScore += 50
        elif pos > 0:
          let prev = cast[ptr char](baseAddr + pos - 1)[]
          if prev in {' ', '-', '_', '/'}:
            localScore += 40
        return localScore
    return 0

## Scalar fuzzy search (shared by both paths)

func scoreTokenFuzzy(startPtr: ptr char, len: int, pattern: string): int =
  ## Scalar fuzzy search.
  ## Used only if exact search fails.
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
          let gap = tIdx - lastMatchIdx - 1
          score -= gap

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
  ## Calculates the relevance score of a package against the query.
  ##
  ## Uses SIMD exact search when available, falls back to scalar.
  ## Returns 0 if no match, or >0 indicating relevance.
  if not ctx.isValid or len == 0:
    return 0
  var totalScore = 0

  for i, token in ctx.lowerTokens:
    var s = scoreTokenExact(textPtr, len, token, ctx.firstCharVecs[i])

    if s == 0:
      s = scoreTokenFuzzy(textPtr, len, token)

    if s == 0:
      return 0
    totalScore += s

  # Boost for matches in short strings (higher density)
  # Using pre-computed queryLen instead of joining tokens every time
  let density = float(ctx.queryLen) / float(len)
  totalScore = int(float(totalScore) * (1.0 + density))

  return min(totalScore, 999)

proc countingSortResults*(buf: var ResultsBuffer) =
  ## Sorts results by score in O(N) using Counting Sort.
  ##
  ## Since scores are bounded (0-1000), Counting Sort is much faster
  ## than Quicksort/Mergesort (O(N log N)).
  if buf.count == 0:
    return

  const MaxScore = 1000
  var counts: array[MaxScore, uint16]

  for i in 0 ..< buf.count:
    let s = buf.scores[i]
    inc(counts[s])

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
