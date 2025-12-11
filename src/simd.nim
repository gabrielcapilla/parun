import nimsimd/sse2
import std/[bitops]

const VectorSize = 16

func toLowerSimd(ch: M128i): M128i {.inline.} =
  let upperTest = mm_and_si128(
    mm_cmpgt_epi8(mm_set1_epi8(0x5B), ch), mm_cmpgt_epi8(ch, mm_set1_epi8(0x40))
  )
  let toLowerAdd = mm_and_si128(upperTest, mm_set1_epi8(0x20))
  result = mm_add_epi8(ch, toLowerAdd)

func findNextMatchPtr(
    pattern: char, textPtr: ptr char, textLen: int, startPos: int
): tuple[pos: int, isWordStart: bool] =
  if startPos >= textLen:
    return (pos: -1, isWordStart: false)

  let patternVec = mm_set1_epi8(pattern.int8)
  var pos = startPos
  let baseAddr = cast[int](textPtr)

  while pos <= textLen - VectorSize:
    let chunkAddr = cast[ptr M128i](baseAddr + pos)
    let textVec = toLowerSimd(mm_loadu_si128(chunkAddr))
    let patternLowerVec = toLowerSimd(patternVec)

    let matches = mm_cmpeq_epi8(textVec, patternLowerVec)
    let matchMask = mm_movemask_epi8(matches)

    if matchMask != 0:
      let offset = countTrailingZeroBits(uint16(matchMask))
      let matchPos = pos + offset

      var isWordStart = false
      if matchPos == 0:
        isWordStart = true
      elif matchPos > 0:
        let prevChar = cast[ptr char](baseAddr + matchPos - 1)[]
        isWordStart = prevChar == ' '

      return (pos: matchPos, isWordStart: isWordStart)

    pos += VectorSize

  if pos < textLen:
    var lastChunk: array[VectorSize, char]
    let remaining = textLen - pos

    copyMem(addr lastChunk[0], cast[pointer](baseAddr + pos), remaining)

    if remaining < VectorSize:
      zeroMem(addr lastChunk[remaining], VectorSize - remaining)

    let textVec = toLowerSimd(mm_loadu_si128(cast[ptr M128i](addr lastChunk[0])))
    let patternLowerVec = toLowerSimd(patternVec)

    let validMask = (1 shl remaining) - 1
    let matches = mm_cmpeq_epi8(textVec, patternLowerVec)
    let matchMask = mm_movemask_epi8(matches) and validMask

    if matchMask != 0:
      let offset = countTrailingZeroBits(uint16(matchMask))
      let matchPos = pos + offset
      if matchPos < textLen:
        var isWordStart = false
        if matchPos == 0:
          isWordStart = true
        elif matchPos > 0:
          let prevChar = cast[ptr char](baseAddr + matchPos - 1)[]
          isWordStart = prevChar == ' '
        return (pos: matchPos, isWordStart: isWordStart)

  return (pos: -1, isWordStart: false)

func scorePackageSimd*(
    pool: string, nameOffset: int32, nameLen: int16, query: string
): int =
  if query.len == 0 or nameLen == 0:
    return 0

  let textPtr = cast[ptr char](unsafeAddr pool[int(nameOffset)])
  let textLen = int(nameLen)

  if query.len > textLen:
    return 0

  var
    score = 0.0'f32
    lastMatchPos = -1
    searchPos = 0
    consecutiveMatches = 0

  for qChar in query:
    let matchResult = findNextMatchPtr(qChar, textPtr, textLen, searchPos)

    if matchResult.pos == -1:
      return 0 # Falta un caracter del query, descarte inmediato

    score += 10.0
    if matchResult.isWordStart:
      score += 20.0

    if lastMatchPos != -1 and matchResult.pos == lastMatchPos + 1:
      consecutiveMatches += 1
      score += float32(consecutiveMatches) * 5.0
    else:
      consecutiveMatches = 0

    # Bonus de Case Sensitive (SIMD busca en minúsculas, aquí premiamos la exactitud)
    let charInText = cast[ptr char](cast[int](textPtr) + matchResult.pos)[]
    if charInText == qChar:
      score += 5.0

    lastMatchPos = matchResult.pos
    searchPos = matchResult.pos + 1

  # Normalización por longitud (densidad de coincidencia)
  let density = float32(query.len) / float32(textLen)
  score *= density

  # Bonus si la coincidencia ocurre al principio del texto
  if lastMatchPos < textLen div 2:
    score *= 1.2

  return int(score)
