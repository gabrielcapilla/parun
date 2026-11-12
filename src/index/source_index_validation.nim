import std/[memfiles, os, tables]
import source_index_core, source_index_codec

proc sectionData(
    memBase: pointer, r: SourceSectionRange
): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](cast[int](memBase) + r.offset)

proc proveRawMap*(
    memBase: pointer,
    offsets, lens, blob: SourceSectionRange,
    itemCount, wordBytes: int,
    label: string,
): string =
  if itemCount < 0 or wordBytes <= 0 or offsets.size < itemCount * wordBytes or
      lens.size < itemCount * 2:
    return label & " offset/len sections are truncated"
  let offsetsData = sectionData(memBase, offsets)
  let lensData = sectionData(memBase, lens)
  for idx in 0 ..< itemCount:
    let off = readPackedWordAt(offsetsData, idx, wordBytes)
    let length = readU16At(lensData, idx)
    if off < 0 or length < 0 or off > blob.size or length > blob.size - off:
      return label & " offset range escapes raw payload"
  ""

proc proveRepoIndices*(
    memBase: pointer,
    indices: SourceSectionRange,
    packageCount, repoCount, repoIndexBytes: int,
): string =
  if packageCount < 0 or repoCount < 0 or repoIndexBytes <= 0 or
      indices.size < packageCount * repoIndexBytes:
    return "repo_idx section is truncated"
  let data = sectionData(memBase, indices)
  for idx in 0 ..< packageCount:
    let repoIdx =
      if repoIndexBytes == 1:
        int(data[idx])
      else:
        readU16At(data, idx)
    if repoIdx < 0 or repoIdx >= repoCount:
      return "repo index exceeds repo count"
  ""

proc proveBucketIds*(
    memBase: pointer,
    offsets, lens, ids: SourceSectionRange,
    packageCount, wordBytes: int,
): string =
  let bucketOffsetsData = sectionData(memBase, offsets)
  let bucketLensData = sectionData(memBase, lens)
  let bucketIdsData = sectionData(memBase, ids)
  let bucketIdCount = ids.size div wordBytes
  for bucketIdx in 0 ..< BucketCount:
    let bucketStart = readPackedWordAt(bucketOffsetsData, bucketIdx, wordBytes)
    let bucketLen = readPackedWordAt(bucketLensData, bucketIdx, wordBytes)
    if bucketStart < 0 or bucketLen < 0 or bucketStart + bucketLen > bucketIdCount:
      return "bucket range escapes bucket id section"
    for idPos in bucketStart ..< bucketStart + bucketLen:
      let packageId = readPackedWordAt(bucketIdsData, idPos, wordBytes)
      if packageId < 0 or packageId >= packageCount:
        return "bucket id exceeds package count"
  ""

proc proveVersionMap*(
    memBase: pointer,
    offsets, lens, blob: SourceSectionRange,
    packageCount, wordBytes: int,
): string =
  if offsets.size < packageCount * wordBytes or lens.size < packageCount * 2:
    return "version offset/len sections are truncated"
  let verRawLen = readU32Bytes(sectionData(memBase, blob), 0).int
  let verOffsetsData = sectionData(memBase, offsets)
  let verLensData = sectionData(memBase, lens)
  for idx in 0 ..< packageCount:
    let off = readPackedWordAt(verOffsetsData, idx, wordBytes)
    let l = readU16At(verLensData, idx)
    if off < 0 or l < 0 or off + l > verRawLen:
      return "version offset range escapes compressed raw payload"
  ""

proc proveRepoMap*(
    memBase: pointer, offsets, lens, blob: SourceSectionRange, repoCount, wordBytes: int
): string =
  if offsets.size < repoCount * wordBytes or lens.size < repoCount * 2:
    return "repo offset/len sections are truncated"
  let repoRawLen = readU32Bytes(sectionData(memBase, blob), 0).int
  let repoOffsetsData = sectionData(memBase, offsets)
  let repoLensData = sectionData(memBase, lens)
  for idx in 0 ..< repoCount:
    let off = readPackedWordAt(repoOffsetsData, idx, wordBytes)
    let l = readU16At(repoLensData, idx)
    if off < 0 or l < 0 or off + l > repoRawLen:
      return "repo offset range escapes compressed raw payload"
  ""

proc validateSourceIndex*(path: string, deep: bool = true): ValidatedSourceIndex =
  result.path = path
  result.deep = deep
  if not fileExists(path):
    result.error = "index file not found"
    return

  var mapped = memfiles.open(path, mode = fmRead)
  defer:
    mapped.close()

  result.fileSize = mapped.size
  if mapped.size < SourceIndexHeaderBytes.int:
    result.error = "index header truncated"
    return

  let data = cast[ptr UncheckedArray[byte]](mapped.mem)
  if data[0].char != 'P' or data[1].char != 'R' or data[2].char != 'I' or
      data[3].char != 'X':
    result.error = "invalid source index magic"
    return

  let version = readU32Bytes(data, 4)
  if version != SourceIndexVersion.int:
    result.error = "unsupported source index version: " & $version
    return
  result.formatVersion = version

  let sourceRaw = readU32Bytes(data, 8)
  if sourceRaw > high(IndexedSourceKind).ord:
    result.error = "invalid source index kind"
    return

  result.source = IndexedSourceKind(sourceRaw)
  result.packageCount = readU32Bytes(data, 12)
  result.repoCount = readU32Bytes(data, 16)
  result.sectionCount = readU32Bytes(data, 20)
  let headerBytes = readU32Bytes(data, 24)
  let headerFlags = readU32Bytes(data, 28)
  result.headerFlags = headerFlags
  let wordBytes =
    if (headerFlags and HeaderFlagWideWords.int) != 0:
      PackedWord32Bytes
    else:
      PackedWord24Bytes
  let repoIndexBytes = if (headerFlags and HeaderFlagNarrowRepoIdx.int) != 0: 1 else: 2

  if headerBytes != SourceIndexHeaderBytes.int:
    result.error = "unexpected header byte size"
    return

  let directoryBytes = result.sectionCount * (SectionNameBytes + 8 + 8)
  if mapped.size < headerBytes + directoryBytes:
    result.error = "section directory truncated"
    return

  let directoryStart = headerBytes
  var seenSections = initTable[SourceSectionId, bool]()
  var sectionRanges: array[SourceSectionId, SourceSectionRange]
  for idx in 0 ..< result.sectionCount:
    let entryBase = directoryStart + idx * (SectionNameBytes + 8 + 8)
    var sectionName = newStringOfCap(SectionNameBytes)
    for i in 0 ..< SectionNameBytes:
      let ch = cast[char](data[entryBase + i])
      if ch == '\x00':
        break
      sectionName.add(ch)
    var sectionId: SourceSectionId
    try:
      sectionId = findSectionId(sectionName)
    except ValueError:
      result.error = getCurrentExceptionMsg()
      return
    if seenSections.hasKey(sectionId):
      result.error = "duplicate section name in directory"
      return
    seenSections[sectionId] = true
    let offset = readU64Bytes(data, entryBase + SectionNameBytes)
    let size = readU64Bytes(data, entryBase + SectionNameBytes + 8)
    if offset < 0 or size < 0 or offset < headerBytes + directoryBytes or
        offset > mapped.size or size > mapped.size - offset:
      result.error = "section range escapes file bounds"
      return
    sectionRanges[sectionId] = SourceSectionRange(offset: offset, size: size)

  let detailSectionIds = {ssDetailOffsets, ssDetailLens, ssDetailBlob}
  var detailSeenCount = 0
  for section in detailSectionIds:
    if seenSections.hasKey(section):
      detailSeenCount.inc()
  if detailSeenCount notin {0, 3}:
    result.error = "detail sections are inconsistent"
    return
  let detailSectionsPresent =
    detailSeenCount == 3 and sectionRanges[ssDetailOffsets].size > 0 and
    sectionRanges[ssDetailLens].size > 0 and sectionRanges[ssDetailBlob].size > 0
  if detailSeenCount == 3 and not detailSectionsPresent and (
    sectionRanges[ssDetailOffsets].size > 0 or sectionRanges[ssDetailLens].size > 0 or
    sectionRanges[ssDetailBlob].size > 0
  ):
    result.error = "detail sections are inconsistent"
    return
  for section in SourceSectionId:
    if not seenSections.hasKey(section):
      if not detailSectionsPresent and section in detailSectionIds:
        continue
      result.error = "missing required section: " & SectionNames[section]
      return

  for section in [
    ssNameOffsets, ssLowerOffsets, ssVersionOffsets, ssRepoOffsets, ssUrlOffsets,
    ssDetailOffsets, ssBucketOffsets, ssBucketLens, ssBucketIds,
  ]:
    if not detailSectionsPresent and section == ssDetailOffsets:
      continue
    var found = false
    for idx in 0 ..< result.sectionCount:
      let entryBase = directoryStart + idx * (SectionNameBytes + 8 + 8)
      var sectionName = newStringOfCap(SectionNameBytes)
      for i in 0 ..< SectionNameBytes:
        let ch = cast[char](data[entryBase + i])
        if ch == '\x00':
          break
        sectionName.add(ch)
      if findSectionId(sectionName) == section:
        let size = readU64Bytes(data, entryBase + SectionNameBytes + 8)
        if size > 0 and (size mod wordBytes) != 0:
          result.error = "invalid packed word section size: " & sectionName
          return
        found = true
        break
    if not found:
      result.error = "missing required section: " & SectionNames[section]
      return

  var repoIndicesFound = false
  for idx in 0 ..< result.sectionCount:
    let entryBase = directoryStart + idx * (SectionNameBytes + 8 + 8)
    var sectionName = newStringOfCap(SectionNameBytes)
    for i in 0 ..< SectionNameBytes:
      let ch = cast[char](data[entryBase + i])
      if ch == '\x00':
        break
      sectionName.add(ch)
    if findSectionId(sectionName) == ssRepoIndices:
      let size = readU64Bytes(data, entryBase + SectionNameBytes + 8)
      if size != result.packageCount * repoIndexBytes:
        result.error = "invalid repo_idx section size"
        return
      repoIndicesFound = true
      break
  if not repoIndicesFound:
    result.error = "missing required section: " & SectionNames[ssRepoIndices]
    return

  let requiredPackageWordBytes = result.packageCount * wordBytes
  let requiredRepoWordBytes = result.repoCount * wordBytes
  let requiredSizes: array[SourceSectionId, int] = [
    requiredPackageWordBytes,
    result.packageCount * 2,
    0,
    0,
    0,
    0,
    requiredPackageWordBytes,
    result.packageCount * 2,
    0,
    result.packageCount * repoIndexBytes,
    result.packageCount,
    requiredRepoWordBytes,
    result.repoCount * 2,
    0,
    requiredPackageWordBytes,
    result.packageCount * 2,
    0,
    result.packageCount * wordBytes,
    result.packageCount * 2,
    0,
    BucketCount * wordBytes,
    BucketCount * wordBytes,
    result.packageCount * wordBytes,
  ]
  for section in SourceSectionId:
    if not detailSectionsPresent and section in detailSectionIds:
      continue
    if sectionRanges[section].size < requiredSizes[section]:
      result.error = "section is truncated: " & SectionNames[section]
      return

  let memBase = cast[pointer](mapped.mem)
  var err = proveRawMap(
    memBase,
    sectionRanges[ssNameOffsets],
    sectionRanges[ssNameLens],
    sectionRanges[ssNameBlob],
    result.packageCount,
    wordBytes,
    "name",
  )
  if err.len > 0:
    result.error = err
    return
  let lowerSectionsPresent =
    sectionRanges[ssLowerOffsets].size > 0 or sectionRanges[ssLowerLens].size > 0 or
    sectionRanges[ssLowerBlob].size > 0
  if lowerSectionsPresent:
    if sectionRanges[ssLowerOffsets].size == 0 or sectionRanges[ssLowerLens].size == 0 or
        sectionRanges[ssLowerBlob].size == 0:
      result.error = "lower name sections are inconsistent"
      return
    err = proveRawMap(
      memBase,
      sectionRanges[ssLowerOffsets],
      sectionRanges[ssLowerLens],
      sectionRanges[ssLowerBlob],
      result.packageCount,
      wordBytes,
      "lower name",
    )
    if err.len > 0:
      result.error = err
      return
  err = proveRepoIndices(
    memBase,
    sectionRanges[ssRepoIndices],
    result.packageCount,
    result.repoCount,
    repoIndexBytes,
  )
  if err.len > 0:
    result.error = err
    return

  let bucketOffsetsRange = sectionRanges[ssBucketOffsets]
  let bucketLensRange = sectionRanges[ssBucketLens]
  if bucketOffsetsRange.size < BucketCount * wordBytes or
      bucketLensRange.size < BucketCount * wordBytes:
    result.error = "bucket offset/len sections are truncated"
    return

  if not deep:
    result.valid = true
    return

  if (headerFlags and HeaderFlagVerBlobCompressed.int) != 0:
    let err = validateCompressedBlobSection(
      sectionData(memBase, sectionRanges[ssVersionBlob]),
      sectionRanges[ssVersionBlob].size,
      SectionNames[ssVersionBlob],
    )
    if err.len > 0:
      result.error = err
      return

  if (headerFlags and HeaderFlagRepoBlobCompressed.int) != 0:
    let err = validateCompressedBlobSection(
      sectionData(memBase, sectionRanges[ssRepoBlob]),
      sectionRanges[ssRepoBlob].size,
      SectionNames[ssRepoBlob],
    )
    if err.len > 0:
      result.error = err
      return

  if (headerFlags and HeaderFlagVerBlobCompressed.int) != 0:
    let err = proveVersionMap(
      memBase,
      sectionRanges[ssVersionOffsets],
      sectionRanges[ssVersionLens],
      sectionRanges[ssVersionBlob],
      result.packageCount,
      wordBytes,
    )
    if err.len > 0:
      result.error = err
      return
  else:
    err = proveRawMap(
      memBase,
      sectionRanges[ssVersionOffsets],
      sectionRanges[ssVersionLens],
      sectionRanges[ssVersionBlob],
      result.packageCount,
      wordBytes,
      "version",
    )
    if err.len > 0:
      result.error = err
      return

  if (headerFlags and HeaderFlagRepoBlobCompressed.int) != 0:
    let err = proveRepoMap(
      memBase,
      sectionRanges[ssRepoOffsets],
      sectionRanges[ssRepoLens],
      sectionRanges[ssRepoBlob],
      result.repoCount,
      wordBytes,
    )
    if err.len > 0:
      result.error = err
      return
  else:
    err = proveRawMap(
      memBase,
      sectionRanges[ssRepoOffsets],
      sectionRanges[ssRepoLens],
      sectionRanges[ssRepoBlob],
      result.repoCount,
      wordBytes,
      "repo",
    )
    if err.len > 0:
      result.error = err
      return

  err = proveRawMap(
    memBase,
    sectionRanges[ssUrlOffsets],
    sectionRanges[ssUrlLens],
    sectionRanges[ssUrlBlob],
    result.packageCount,
    wordBytes,
    "url",
  )
  if err.len > 0:
    result.error = err
    return

  if detailSectionsPresent:
    err = proveRawMap(
      memBase,
      sectionRanges[ssDetailOffsets],
      sectionRanges[ssDetailLens],
      sectionRanges[ssDetailBlob],
      result.packageCount,
      wordBytes,
      "detail",
    )
    if err.len > 0:
      result.error = err
      return

  let bucketErr = proveBucketIds(
    memBase,
    sectionRanges[ssBucketOffsets],
    sectionRanges[ssBucketLens],
    sectionRanges[ssBucketIds],
    result.packageCount,
    wordBytes,
  )
  if bucketErr.len > 0:
    result.error = bucketErr
    return

  result.valid = true
