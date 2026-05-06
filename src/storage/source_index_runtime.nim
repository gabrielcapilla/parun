## Runtime reader for validated immutable source indexes.
##
## Notes:
## - Exposes hot-path pointer/length accessors (`namePtr`, `bucketRange`, ...).
## - Version and repository cold fields can be served from raw blobs or
##   compressed block containers; URL fields are stored as raw cold slices.
## - No mutable package corpus is reconstructed during normal query flow.
import std/memfiles
import source_index_core, source_index_codec, source_index_validation

var prefaultTouchSink: uint8

proc sectionPtr(
    view: ptr SourceIndexView, section: SourceSectionId
): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](cast[int](view[].file.mem) +
    view[].sections[section].offset)

proc sectionLen*(view: ptr SourceIndexView, section: SourceSectionId): int {.inline.} =
  view[].sections[section].size

proc packageCount*(view: ptr SourceIndexView): int {.inline, noSideEffect.} =
  view[].packageCount

proc repoCount*(view: ptr SourceIndexView): int {.inline, noSideEffect.} =
  view[].repoCount

proc valid*(view: ptr SourceIndexView): bool {.inline, noSideEffect.} =
  ## True when view points to a mapped/initialized index.
  not view.isNil and view[].mapped and view[].packageCount >= 0

proc lowerNameOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  if view.sectionLen(ssLowerOffsets) > 0:
    readPackedWordAt(view.sectionPtr(ssLowerOffsets), idx, view.wordBytes)
  else:
    readPackedWordAt(view.sectionPtr(ssNameOffsets), idx, view.wordBytes)

proc nameOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readPackedWordAt(view.sectionPtr(ssNameOffsets), idx, view.wordBytes)

proc versionOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readPackedWordAt(view.sectionPtr(ssVersionOffsets), idx, view.wordBytes)

proc repoOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readPackedWordAt(view.sectionPtr(ssRepoOffsets), idx, view.wordBytes)

proc urlOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  if view.sectionLen(ssUrlOffsets) == 0:
    return 0
  readPackedWordAt(view.sectionPtr(ssUrlOffsets), idx, view.wordBytes)

proc repoIndex*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  if view.repoIndexBytes == 1:
    int(view.sectionPtr(ssRepoIndices)[idx])
  else:
    readU16At(view.sectionPtr(ssRepoIndices), idx)

proc getNameLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssNameLens), idx)

proc getLowerLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  if view.sectionLen(ssLowerLens) > 0:
    readU16At(view.sectionPtr(ssLowerLens), idx)
  else:
    readU16At(view.sectionPtr(ssNameLens), idx)

proc getVersionLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssVersionLens), idx)

proc getRepoLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssRepoLens), view.repoIndex(idx))

proc getUrlLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  if view.sectionLen(ssUrlLens) == 0:
    return 0
  readU16At(view.sectionPtr(ssUrlLens), idx)

proc isInstalled*(view: ptr SourceIndexView, idx: int): bool {.inline.} =
  (view.sectionPtr(ssFlags)[idx] and 1'u8) != 0

proc namePtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssNameBlob)[view.nameOffset(idx)])

proc lowerNamePtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  if view.sectionLen(ssLowerBlob) > 0:
    cast[ptr char](addr view.sectionPtr(ssLowerBlob)[view.lowerNameOffset(idx)])
  else:
    cast[ptr char](addr view.sectionPtr(ssNameBlob)[view.nameOffset(idx)])

proc versionPtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssVersionBlob)[view.versionOffset(idx)])

proc repoPtr*(view: ptr SourceIndexView, repoIdx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssRepoBlob)[view.repoOffset(repoIdx)])

proc urlPtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssUrlBlob)[view.urlOffset(idx)])

proc appendSlice(
    ptrBase: ptr char, sliceLen: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  var copyLen = sliceLen
  if maxLen >= 0 and maxLen < copyLen:
    copyLen = maxLen
  if copyLen <= 0:
    return
  let baseLen = buffer.len
  buffer.setLen(baseLen + copyLen)
  copyMem(addr buffer[baseLen], ptrBase, copyLen)

proc appendName*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Appends package name bytes for `idx`.
  appendSlice(view.namePtr(idx), view.getNameLen(idx), buffer, maxLen)

proc appendVersion*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Appends package version bytes for `idx` (compressed or raw path).
  let vLen = view.getVersionLen(idx)
  if view.versionBlobMeta.enabled:
    appendCompressedBlobSlice(
      view,
      ssVersionBlob,
      view[].versionBlobMeta,
      view.versionOffset(idx),
      vLen,
      buffer,
      maxLen,
    )
  else:
    appendSlice(view.versionPtr(idx), vLen, buffer, maxLen)

proc appendRepo*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Appends repository name bytes for `idx`.
  let repoIdx = view.repoIndex(idx)
  let rLen = readU16At(view.sectionPtr(ssRepoLens), repoIdx)
  if view.repoBlobMeta.enabled:
    appendCompressedBlobSlice(
      view,
      ssRepoBlob,
      view[].repoBlobMeta,
      view.repoOffset(repoIdx),
      rLen,
      buffer,
      maxLen,
    )
  else:
    appendSlice(view.repoPtr(repoIdx), rLen, buffer, maxLen)

proc appendUrl*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  ## Appends package source URL bytes for `idx` when present.
  let uLen = view.getUrlLen(idx)
  if uLen <= 0:
    return
  appendSlice(view.urlPtr(idx), uLen, buffer, maxLen)

proc copyName*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getNameLen(idx))
  view.appendName(idx, result)

proc copyVersion*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getVersionLen(idx))
  view.appendVersion(idx, result)

proc copyRepo*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getRepoLen(idx))
  view.appendRepo(idx, result)

proc copyUrl*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getUrlLen(idx))
  view.appendUrl(idx, result)

proc copyPkgId*(view: ptr SourceIndexView, idx: int): string =
  let repoLen = view.getRepoLen(idx)
  let nameLen = view.getNameLen(idx)
  result = newStringOfCap(repoLen + 1 + nameLen)
  view.appendRepo(idx, result)
  result.add('/')
  view.appendName(idx, result)

proc predecodeColdFields*(view: ptr SourceIndexView, idx: int) =
  ## Opportunistically pre-decodes cold version/repo blocks around a focused row.
  if not view.valid:
    return
  if idx < 0 or idx >= packageCount(view):
    return

  if view.versionBlobMeta.enabled:
    let vLen = view.getVersionLen(idx)
    if vLen > 0:
      let vOffset = view.versionOffset(idx)
      let startBlock = vOffset div view.versionBlobMeta.blockBytes
      let endBlock = (vOffset + vLen - 1) div view.versionBlobMeta.blockBytes
      for blockIdx in startBlock .. endBlock:
        var blockData = ""
        var blockRawLen = 0
        discard decodeCompressedBlobBlock(
          view, ssVersionBlob, view[].versionBlobMeta, blockIdx, blockData, blockRawLen
        )

  if view.repoBlobMeta.enabled:
    let rIdx = view.repoIndex(idx)
    let rLen = readU16At(view.sectionPtr(ssRepoLens), rIdx)
    if rLen > 0:
      let rOffset = view.repoOffset(rIdx)
      let startBlock = rOffset div view.repoBlobMeta.blockBytes
      let endBlock = (rOffset + rLen - 1) div view.repoBlobMeta.blockBytes
      for blockIdx in startBlock .. endBlock:
        var blockData = ""
        var blockRawLen = 0
        discard decodeCompressedBlobBlock(
          view, ssRepoBlob, view[].repoBlobMeta, blockIdx, blockData, blockRawLen
        )

proc bucketRange*(view: ptr SourceIndexView, firstByte: uint8): Slice[int] {.inline.} =
  ## Returns posting-list range for first-byte candidate narrowing.
  let bucketIndex = int(firstByte)
  let start =
    readPackedWordAt(view.sectionPtr(ssBucketOffsets), bucketIndex, view.wordBytes)
  let count =
    readPackedWordAt(view.sectionPtr(ssBucketLens), bucketIndex, view.wordBytes)
  start ..< start + count

proc bucketIdAt*(view: ptr SourceIndexView, position: int): int {.inline.} =
  readPackedWordAt(view.sectionPtr(ssBucketIds), position, view.wordBytes)

proc mappedHotBytes*(view: ptr SourceIndexView): int =
  result =
    view.sectionLen(ssNameOffsets) + view.sectionLen(ssNameLens) +
    view.sectionLen(ssLowerOffsets) + view.sectionLen(ssLowerLens) +
    view.sectionLen(ssLowerBlob) + view.sectionLen(ssRepoIndices) +
    view.sectionLen(ssFlags) + view.sectionLen(ssBucketOffsets) +
    view.sectionLen(ssBucketLens) + view.sectionLen(ssBucketIds)

proc mappedColdBytes*(view: ptr SourceIndexView): int =
  result =
    view.sectionLen(ssVersionOffsets) + view.sectionLen(ssVersionLens) +
    view.sectionLen(ssVersionBlob) + view.sectionLen(ssRepoOffsets) +
    view.sectionLen(ssRepoLens) + view.sectionLen(ssRepoBlob) +
    view.sectionLen(ssUrlOffsets) + view.sectionLen(ssUrlLens) +
    view.sectionLen(ssUrlBlob)

proc prefaultHotSections*(view: ptr SourceIndexView) =
  ## Touches representative bytes in hot sections to reduce first-hit page faults.
  if not view.valid:
    return
  var sink: uint8 = 0
  for section in [
    ssNameOffsets, ssNameLens, ssLowerOffsets, ssLowerLens, ssRepoIndices, ssFlags,
    ssBucketOffsets, ssBucketLens,
  ]:
    let bytes = view.sectionLen(section)
    if bytes <= 0:
      continue
    let ptrData = view.sectionPtr(section)
    sink = sink xor ptrData[0]
    sink = sink xor ptrData[bytes - 1]
  if view[].packageCount > 0:
    sink = sink xor uint8(view.getNameLen(0))
  prefaultTouchSink = sink

proc close*(view: var SourceIndexView) =
  if view.mapped:
    view.file.close()
    view = default(SourceIndexView)

proc openSourceIndex*(path: string): SourceIndexView =
  ## Opens and maps a previously validated source index file.
  let validated = validateSourceIndex(path)
  if not validated.valid:
    raise
      newException(IOError, "invalid source index '" & path & "': " & validated.error)

  result.path = path
  result.source = validated.source
  result.packageCount = validated.packageCount
  result.repoCount = validated.repoCount
  result.sectionCount = validated.sectionCount
  result.fileSize = validated.fileSize
  result.headerFlags = validated.headerFlags
  result.file = memfiles.open(path, mode = fmRead)
  result.mapped =
    result.file.mem != nil and result.file.size >= SourceIndexHeaderBytes.int
  result.wordBytes =
    if (result.headerFlags and HeaderFlagWideWords.int) != 0:
      PackedWord32Bytes
    else:
      PackedWord24Bytes
  result.repoIndexBytes =
    if (result.headerFlags and HeaderFlagNarrowRepoIdx.int) != 0: 1 else: 2
  let base = cast[ptr UncheckedArray[byte]](result.file.mem)

  let directoryStart = SourceIndexHeaderBytes.int
  for idx in 0 ..< validated.sectionCount:
    let entryBase = directoryStart + idx * (SectionNameBytes + 8 + 8)
    let rawName = cast[ptr UncheckedArray[char]](cast[int](result.file.mem) + entryBase)
    var sectionName = newStringOfCap(SectionNameBytes)
    for i in 0 ..< SectionNameBytes:
      let ch = rawName[i]
      if ch == '\x00':
        break
      sectionName.add(ch)
    let sectionId = findSectionId(sectionName)
    result.sections[sectionId] = SourceSectionRange(
      offset: readU64Bytes(base, entryBase + SectionNameBytes),
      size: readU64Bytes(base, entryBase + SectionNameBytes + 8),
    )

  result.versionBlobMeta = initCompressedBlobMeta(
    addr result,
    ssVersionBlob,
    (result.headerFlags and HeaderFlagVerBlobCompressed.int) != 0,
  )
  result.repoBlobMeta = initCompressedBlobMeta(
    addr result,
    ssRepoBlob,
    (result.headerFlags and HeaderFlagRepoBlobCompressed.int) != 0,
  )

proc openValidatedSourceIndex*(validated: ValidatedSourceIndex): SourceIndexView =
  ## Opens source index using precomputed validation result.
  if not validated.valid:
    raise newException(
      IOError, "invalid source index '" & validated.path & "': " & validated.error
    )
  openSourceIndex(validated.path)
