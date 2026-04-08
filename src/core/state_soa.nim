import std/bitops
import types

proc appendFromArena*(
    textArena: openArray[char], offset, len: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  if offset < 0 or len < 0:
    return

  var copyLen = len
  if maxLen >= 0 and maxLen < len:
    copyLen = maxLen
  if copyLen <= 0:
    return

  let endOffset = offset + copyLen
  if endOffset > textArena.len:
    copyLen = textArena.len - offset
    if copyLen <= 0:
      return

  let currentLen = buffer.len
  buffer.setLen(currentLen + copyLen)
  if textArena.len > 0 and copyLen > 0:
    copyMem(addr buffer[currentLen], unsafeAddr textArena[offset], copyLen)

proc appendName*(
    soa: PackageSOA,
    textArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let offset = int(soa.hot.locators[idx])
  let len = int(soa.hot.nameLens[idx])
  appendFromArena(textArena, offset, len, buffer, maxLen)

proc appendVersion*(
    soa: PackageSOA,
    textArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let nameLen = int(soa.hot.nameLens[idx])
  let offset = int(soa.hot.locators[idx]) + nameLen
  let len = int(soa.cold.verLens[idx])
  appendFromArena(textArena, offset, len, buffer, maxLen)

proc appendRepo*(
    soa: PackageSOA,
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int,
    buffer: var string,
    maxLen: int = -1,
) =
  let rIdx = soa.cold.repoIndices[idx]
  let rOffset = int(repoOffsets[rIdx])
  let rLen = int(repoLens[int(rIdx)])
  var copyLen = rLen
  if maxLen >= 0 and maxLen < rLen:
    copyLen = maxLen

  if copyLen > 0:
    let currentLen = buffer.len
    buffer.setLen(currentLen + copyLen)
    copyMem(addr buffer[currentLen], unsafeAddr repoArena[rOffset], copyLen)

func getNameLen*(soa: PackageSOA, idx: int): int {.inline, noSideEffect.} =
  int(soa.hot.nameLens[idx])

func getVersionLen*(soa: PackageSOA, idx: int): int {.inline, noSideEffect.} =
  int(soa.cold.verLens[idx])

func getRepoLen*(
    soa: PackageSOA, repoLens: openArray[uint8], idx: int
): int {.inline, noSideEffect.} =
  int(repoLens[int(soa.cold.repoIndices[idx])])

func getName*(soa: PackageSOA, textArena: openArray[char], idx: int): string =
  result = newStringOfCap(getNameLen(soa, idx))
  appendName(soa, textArena, idx, result)

func getVersion*(soa: PackageSOA, textArena: openArray[char], idx: int): string =
  result = newStringOfCap(getVersionLen(soa, idx))
  appendVersion(soa, textArena, idx, result)

func getRepo*(
    soa: PackageSOA,
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int,
): string =
  let rIdx = int(soa.cold.repoIndices[idx])
  let repoOffset = int(repoOffsets[rIdx])
  let repoLen = int(repoLens[int(soa.cold.repoIndices[idx])])
  if repoOffset + repoLen <= repoArena.len:
    result = newStringOfCap(repoLen)
    result.setLen(repoLen)
    copyMem(addr result[0], unsafeAddr repoArena[repoOffset], repoLen)
    return result
  ""

func getPkgId*(
    soa: PackageSOA,
    textArena: openArray[char],
    repoOffsets: openArray[uint16],
    repoLens: openArray[uint8],
    repoArena: openArray[char],
    idx: int32,
): string {.noSideEffect.} =
  getRepo(soa, repoOffsets, repoLens, repoArena, int(idx)) & "/" &
    getName(soa, textArena, int(idx))

func isSelected*(
    selectionBits: openArray[uint64], idx: int
): bool {.inline, noSideEffect.} =
  let wordIdx = idx div 64
  if wordIdx >= selectionBits.len:
    return false
  testBit(selectionBits[wordIdx], idx mod 64)

proc toggleSelection*(state: var AppState, idx: int) =
  let wordIdx = idx div 64
  if wordIdx >= state.selectionBits.len:
    state.selectionBits.setLen(wordIdx + 1)
  state.selectionBits[wordIdx] =
    state.selectionBits[wordIdx] xor (1'u64 shl (idx mod 64))

func getSelectedCount*(selectionBits: openArray[uint64]): int {.noSideEffect.} =
  result = 0
  for word in selectionBits:
    result += countSetBits(word)
