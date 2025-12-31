## Implements hardware-accelerated text search using SSE2 instructions.
## Processes 16 characters simultaneously per CPU cycle.
##
## Performance:
## - Approx. 16x faster than scalar character-by-character comparison.
## - Minimizes branch mispredictions.

import nimsimd/sse2
import std/[bitops, strutils]
import ../core/types

const VectorSize = 16

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
  firstCharVecs*: seq[M128i]
    ## SIMD vectors with the first char of each token broadcasted.

func toLowerSimd(ch: M128i): M128i {.inline.} =
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

func prepareSearchContext*(query: string): SearchContext =
  ## Prepares the SIMD context for a new query.
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
        if (cast[ptr char](baseAddr + pos + k)[]).toLowerAscii != pattern[k].toLowerAscii:
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
  ## Combines SIMD exact search and scalar fuzzy search.
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
  let density = float(ctx.tokens.join(" ").len) / float(len)
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
  for s in 0 ..< MaxScore:
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

  # Reverse for descending order (highest score first)
  for i in 0 ..< buf.count:
    buf.indices[i] = outputIndices[buf.count - 1 - i]
    buf.scores[i] = outputScores[buf.count - 1 - i]
