import nimsimd/sse2
import std/[bitops, strutils]

const VectorSize = 16

type SearchContext* = object
  isValid*: bool
  tokens*: seq[string]
  firstCharVecs*: seq[M128i]

func toLowerSimd(ch: M128i): M128i {.inline.} =
  let rangeLow = mm_set1_epi8(0x40)
  let rangeHigh = mm_set1_epi8(0x5B)
  let diff = mm_set1_epi8(0x20)

  let upperTest =
    mm_and_si128(mm_cmpgt_epi8(rangeHigh, ch), mm_cmpgt_epi8(ch, rangeLow))
  let toLowerAdd = mm_and_si128(upperTest, diff)
  result = mm_add_epi8(ch, toLowerAdd)

func prepareSearchContext*(query: string): SearchContext =
  let clean = query.strip()
  if clean.len == 0:
    return SearchContext(isValid: false)

  result.isValid = true
  result.tokens = clean.splitWhitespace()
  result.firstCharVecs = newSeq[M128i](result.tokens.len)

  for i, token in result.tokens:
    if token.len > 0:
      result.firstCharVecs[i] = mm_set1_epi8(token[0].toLowerAscii.ord.int8)

func scoreToken(startPtr: ptr char, len: int, pattern: string, patternVec: M128i): int =
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
            var localScore = 10
            if matchPos == 0:
              localScore += 20
            elif matchPos > 0:
              let prev = cast[ptr char](baseAddr + matchPos - 1)[]
              if prev in {' ', '-', '_', '/'}:
                localScore += 20

            if (cast[ptr char](baseAddr + matchPos)[] == pattern[0]):
              localScore += 5
            return localScore

        currentMask = currentMask and not (1.uint16 shl offset)

    pos += VectorSize

  while pos <= len - patternLen:
    let c = (cast[ptr char](baseAddr + pos)[]).toLowerAscii
    if c == pattern[0].toLowerAscii:
      var fullMatch = true
      for k in 1 ..< patternLen:
        if (cast[ptr char](baseAddr + pos + k)[]).toLowerAscii != pattern[k].toLowerAscii:
          fullMatch = false
          break
      if fullMatch:
        var localScore = 10
        if pos == 0:
          localScore += 20
        elif pos > 0:
          let prev = cast[ptr char](baseAddr + pos - 1)[]
          if prev in {' ', '-', '_'}:
            localScore += 20
        return localScore
    pos += 1

  return 0

func scorePackageSimd*(textPtr: ptr char, len: int, ctx: SearchContext): int =
  if not ctx.isValid or len == 0:
    return 0

  var totalScore = 0

  for i, token in ctx.tokens:
    let s = scoreToken(textPtr, len, token, ctx.firstCharVecs[i])
    if s == 0:
      return 0
    totalScore += s

  let density = float(ctx.tokens.join(" ").len) / float(len)
  totalScore = int(float(totalScore) * (1.0 + density))

  return totalScore
