import std/[memfiles, os, tables]
import source_index_core, source_index_codec

proc validateSourceIndex*(path: string): ValidatedSourceIndex =
  result.path = path
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
  if version != SourceIndexVersion.int and version != LegacySourceIndexVersion.int:
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
    let sectionId = findSectionId(sectionName)
    if seenSections.hasKey(sectionId):
      result.error = "duplicate section name in directory"
      return
    seenSections[sectionId] = true
    let offset = readU64Bytes(data, entryBase + SectionNameBytes)
    let size = readU64Bytes(data, entryBase + SectionNameBytes + 8)
    if offset < headerBytes + directoryBytes or offset + size > mapped.size:
      result.error = "section range escapes file bounds"
      return
    sectionRanges[sectionId] = SourceSectionRange(offset: offset, size: size)

  for section in SourceSectionId:
    if not seenSections.hasKey(section):
      result.error = "missing required section: " & SectionNames[section]
      return

  for section in [
    ssNameOffsets, ssLowerOffsets, ssVersionOffsets, ssRepoOffsets, ssBucketOffsets,
    ssBucketLens, ssBucketIds,
  ]:
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

  if (headerFlags and HeaderFlagVerBlobCompressed.int) != 0:
    let range = sectionRanges[ssVersionBlob]
    let err = validateCompressedBlobSection(
      cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) + range.offset),
      range.size,
      SectionNames[ssVersionBlob],
    )
    if err.len > 0:
      result.error = err
      return

  if (headerFlags and HeaderFlagRepoBlobCompressed.int) != 0:
    let range = sectionRanges[ssRepoBlob]
    let err = validateCompressedBlobSection(
      cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) + range.offset),
      range.size,
      SectionNames[ssRepoBlob],
    )
    if err.len > 0:
      result.error = err
      return

  if (headerFlags and HeaderFlagVerBlobCompressed.int) != 0:
    if sectionRanges[ssVersionOffsets].size < result.packageCount * wordBytes or
        sectionRanges[ssVersionLens].size < result.packageCount * 2:
      result.error = "version offset/len sections are truncated"
      return
    let verBlobData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssVersionBlob].offset)
    let verRawLen = readU32Bytes(verBlobData, 0)
    let verOffsetsData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssVersionOffsets].offset)
    let verLensData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssVersionLens].offset)
    for idx in 0 ..< result.packageCount:
      let off = readPackedWordAt(verOffsetsData, idx, wordBytes)
      let l = readU16At(verLensData, idx)
      if off < 0 or l < 0 or off + l > verRawLen:
        result.error = "version offset range escapes compressed raw payload"
        return

  if (headerFlags and HeaderFlagRepoBlobCompressed.int) != 0:
    if sectionRanges[ssRepoOffsets].size < result.repoCount * wordBytes or
        sectionRanges[ssRepoLens].size < result.repoCount * 2:
      result.error = "repo offset/len sections are truncated"
      return
    let repoBlobData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssRepoBlob].offset)
    let repoRawLen = readU32Bytes(repoBlobData, 0)
    let repoOffsetsData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssRepoOffsets].offset)
    let repoLensData = cast[ptr UncheckedArray[byte]](cast[int](mapped.mem) +
      sectionRanges[ssRepoLens].offset)
    for idx in 0 ..< result.repoCount:
      let off = readPackedWordAt(repoOffsetsData, idx, wordBytes)
      let l = readU16At(repoLensData, idx)
      if off < 0 or l < 0 or off + l > repoRawLen:
        result.error = "repo offset range escapes compressed raw payload"
        return

  result.valid = true
