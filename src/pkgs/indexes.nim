import std/[memfiles, os, streams, strutils, tables]

const
  SourceIndexMagic* = "PRIX"
  SourceIndexVersion* = 3'u32
  SourceIndexHeaderBytes* = 32'u32
  SectionNameBytes = 16
  BucketCount* = 256

type
  SourceSectionId* = enum
    ssNameOffsets
    ssNameLens
    ssNameBlob
    ssLowerOffsets
    ssLowerLens
    ssLowerBlob
    ssVersionOffsets
    ssVersionLens
    ssVersionBlob
    ssRepoIndices
    ssFlags
    ssRepoOffsets
    ssRepoLens
    ssRepoBlob
    ssBucketOffsets
    ssBucketLens
    ssBucketIds

type
  IndexedSourceKind* = enum
    iskSystem
    iskAur
    iskNimble

  IndexedPackageRecord* = object
    name*: string
    version*: string
    repo*: string
    installed*: bool

  SourceIndexStats* = object
    path*: string
    source*: IndexedSourceKind
    packageCount*: int
    repoCount*: int
    fileSize*: int

  ValidatedSourceIndex* = object
    error*: string
    path*: string
    packageCount*: int
    repoCount*: int
    sectionCount*: int
    fileSize*: int
    source*: IndexedSourceKind
    valid*: bool

  SourceSectionRange* = object
    offset*: int
    size*: int

  SourceIndexView* = object
    path*: string
    file*: MemFile
    sections*: array[SourceSectionId, SourceSectionRange]
    packageCount*: int
    repoCount*: int
    sectionCount*: int
    fileSize*: int
    source*: IndexedSourceKind
    mapped*: bool

  SectionPayload = object
    name: string
    data: string

const
  SectionNames: array[SourceSectionId, string] = [
    "name_off",
    "name_len",
    "name_blob",
    "lower_off",
    "lower_len",
    "lower_blob",
    "ver_off",
    "ver_len",
    "ver_blob",
    "repo_idx",
    "flags",
    "repo_off",
    "repo_len",
    "repo_blob",
    "bucket_off",
    "bucket_len",
    "bucket_ids",
  ]

proc addLe16(dst: var string, value: uint16) =
  dst.add(char(value and 0xFF))
  dst.add(char((value shr 8) and 0xFF))

proc addLe32(dst: var string, value: uint32) =
  dst.add(char(value and 0xFF))
  dst.add(char((value shr 8) and 0xFF))
  dst.add(char((value shr 16) and 0xFF))
  dst.add(char((value shr 24) and 0xFF))

proc addLe64(dst: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    dst.add(char((value shr shift) and 0xFF))

proc checkedU16(value: int, label: string): uint16 =
  if value < 0 or value > high(uint16).int:
    raise newException(ValueError, label & " exceeds uint16 range")
  uint16(value)

proc checkedU32(value: int, label: string): uint32 =
  if value < 0 or value > high(uint32).int:
    raise newException(ValueError, label & " exceeds uint32 range")
  uint32(value)

proc sourceTag*(kind: IndexedSourceKind): string =
  case kind
  of iskSystem:
    "system"
  of iskAur:
    "aur"
  of iskNimble:
    "nimble"

proc findSectionId(name: string): SourceSectionId =
  for section in SourceSectionId:
    if SectionNames[section] == name:
      return section
  raise newException(ValueError, "unknown source index section: " & name)

proc addUint32Value(dst: var string, value: uint32) {.inline.} =
  dst.addLe32(value)

proc readU16At(data: ptr UncheckedArray[byte], index: int): int {.inline.} =
  int(data[index * 2]) or (int(data[index * 2 + 1]) shl 8)

proc readU32At(data: ptr UncheckedArray[byte], index: int): int {.inline.} =
  int(data[index * 4]) or
    (int(data[index * 4 + 1]) shl 8) or
    (int(data[index * 4 + 2]) shl 16) or
    (int(data[index * 4 + 3]) shl 24)

proc readU32Bytes(data: ptr UncheckedArray[byte], byteOffset: int): int {.inline.} =
  int(data[byteOffset]) or
    (int(data[byteOffset + 1]) shl 8) or
    (int(data[byteOffset + 2]) shl 16) or
    (int(data[byteOffset + 3]) shl 24)

proc readU64Bytes(data: ptr UncheckedArray[byte], byteOffset: int): int {.inline.} =
  result = 0
  for i in 0 ..< 8:
    result = result or (int(data[byteOffset + i]) shl (8 * i))

proc sectionPtr(view: ptr SourceIndexView, section: SourceSectionId): ptr UncheckedArray[byte] {.
    inline.} =
  cast[ptr UncheckedArray[byte]](cast[int](view[].file.mem) + view[].sections[section].offset)

proc sectionLen*(view: ptr SourceIndexView, section: SourceSectionId): int {.inline.} =
  view[].sections[section].size

proc packageCount*(view: ptr SourceIndexView): int {.inline, noSideEffect.} =
  view[].packageCount

proc repoCount*(view: ptr SourceIndexView): int {.inline, noSideEffect.} =
  view[].repoCount

proc valid*(view: ptr SourceIndexView): bool {.inline, noSideEffect.} =
  not view.isNil and view[].mapped and view[].packageCount >= 0

proc lowerNameOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU32At(view.sectionPtr(ssLowerOffsets), idx)

proc nameOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU32At(view.sectionPtr(ssNameOffsets), idx)

proc versionOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU32At(view.sectionPtr(ssVersionOffsets), idx)

proc repoOffset(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU32At(view.sectionPtr(ssRepoOffsets), idx)

proc repoIndex*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssRepoIndices), idx)

proc getNameLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssNameLens), idx)

proc getLowerLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssLowerLens), idx)

proc getVersionLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssVersionLens), idx)

proc getRepoLen*(view: ptr SourceIndexView, idx: int): int {.inline.} =
  readU16At(view.sectionPtr(ssRepoLens), view.repoIndex(idx))

proc isInstalled*(view: ptr SourceIndexView, idx: int): bool {.inline.} =
  (view.sectionPtr(ssFlags)[idx] and 1'u8) != 0

proc namePtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssNameBlob)[view.nameOffset(idx)])

proc lowerNamePtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssLowerBlob)[view.lowerNameOffset(idx)])

proc versionPtr*(view: ptr SourceIndexView, idx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssVersionBlob)[view.versionOffset(idx)])

proc repoPtr*(view: ptr SourceIndexView, repoIdx: int): ptr char {.inline.} =
  cast[ptr char](addr view.sectionPtr(ssRepoBlob)[view.repoOffset(repoIdx)])

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
  appendSlice(view.namePtr(idx), view.getNameLen(idx), buffer, maxLen)

proc appendVersion*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  appendSlice(view.versionPtr(idx), view.getVersionLen(idx), buffer, maxLen)

proc appendRepo*(
    view: ptr SourceIndexView, idx: int, buffer: var string, maxLen: int = -1
) {.inline.} =
  let repoIdx = view.repoIndex(idx)
  appendSlice(view.repoPtr(repoIdx), readU16At(view.sectionPtr(ssRepoLens), repoIdx), buffer, maxLen)

proc copyName*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getNameLen(idx))
  view.appendName(idx, result)

proc copyVersion*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getVersionLen(idx))
  view.appendVersion(idx, result)

proc copyRepo*(view: ptr SourceIndexView, idx: int): string =
  result = newStringOfCap(view.getRepoLen(idx))
  view.appendRepo(idx, result)

proc copyPkgId*(view: ptr SourceIndexView, idx: int): string =
  let repoLen = view.getRepoLen(idx)
  let nameLen = view.getNameLen(idx)
  result = newStringOfCap(repoLen + 1 + nameLen)
  view.appendRepo(idx, result)
  result.add('/')
  view.appendName(idx, result)

proc bucketRange*(view: ptr SourceIndexView, firstByte: uint8): Slice[int] {.inline.} =
  let bucketIndex = int(firstByte)
  let start = readU32At(view.sectionPtr(ssBucketOffsets), bucketIndex)
  let count = readU32At(view.sectionPtr(ssBucketLens), bucketIndex)
  start ..< start + count

proc bucketIdAt*(view: ptr SourceIndexView, position: int): int {.inline.} =
  readU32At(view.sectionPtr(ssBucketIds), position)

proc mappedHotBytes*(view: ptr SourceIndexView): int =
  result =
    view.sectionLen(ssNameOffsets) +
    view.sectionLen(ssNameLens) +
    view.sectionLen(ssLowerOffsets) +
    view.sectionLen(ssLowerLens) +
    view.sectionLen(ssLowerBlob) +
    view.sectionLen(ssRepoIndices) +
    view.sectionLen(ssFlags) +
    view.sectionLen(ssBucketOffsets) +
    view.sectionLen(ssBucketLens) +
    view.sectionLen(ssBucketIds)

proc mappedColdBytes*(view: ptr SourceIndexView): int =
  result =
    view.sectionLen(ssVersionOffsets) +
    view.sectionLen(ssVersionLens) +
    view.sectionLen(ssVersionBlob) +
    view.sectionLen(ssRepoOffsets) +
    view.sectionLen(ssRepoLens) +
    view.sectionLen(ssRepoBlob)

proc prefaultHotSections*(view: ptr SourceIndexView) =
  if not view.valid:
    return
  var sink: uint8 = 0
  for section in [
    ssNameOffsets,
    ssNameLens,
    ssLowerOffsets,
    ssLowerLens,
    ssRepoIndices,
    ssFlags,
    ssBucketOffsets,
    ssBucketLens,
  ]:
    let bytes = view.sectionLen(section)
    if bytes <= 0:
      continue
    let ptrData = view.sectionPtr(section)
    sink = sink xor ptrData[0]
    sink = sink xor ptrData[bytes - 1]
  if view[].packageCount > 0:
    sink = sink xor uint8(view.getNameLen(0))
  discard sink

proc close*(view: var SourceIndexView) =
  if view.mapped:
    view.file.close()
    view = default(SourceIndexView)

proc buildSourceIndex*(
    source: IndexedSourceKind, packages: openArray[IndexedPackageRecord], outPath: string
): SourceIndexStats =
  var repoMap = initOrderedTable[string, uint16]()
  var buckets: array[BucketCount, seq[uint32]]
  var repoOffsets, repoLens, repoIndices, flags: string
  var nameOffsets, nameLens, lowerOffsets, lowerLens: string
  var verOffsets, verLens: string
  var bucketOffsets, bucketLens, bucketIds: string
  var nameBlob, lowerBlob, verBlob, repoBlob: string
  var emittedCount = 0

  for pkg in packages:
    if pkg.name.len == 0:
      continue

    if pkg.name.len > high(uint16).int:
      raise newException(ValueError, "package name too long for index: " & pkg.name)
    if pkg.version.len > high(uint16).int:
      raise newException(ValueError, "package version too long for index: " & pkg.name)

    nameOffsets.addLe32(checkedU32(nameBlob.len, "name blob offset"))
    nameLens.addLe16(checkedU16(pkg.name.len, "name length"))
    nameBlob.add(pkg.name)

    let lowered = pkg.name.toLowerAscii()
    lowerOffsets.addLe32(checkedU32(lowerBlob.len, "lower blob offset"))
    lowerLens.addLe16(checkedU16(lowered.len, "lower length"))
    lowerBlob.add(lowered)

    verOffsets.addLe32(checkedU32(verBlob.len, "version blob offset"))
    verLens.addLe16(checkedU16(pkg.version.len, "version length"))
    verBlob.add(pkg.version)

    var repoIdx: uint16
    if repoMap.hasKey(pkg.repo):
      repoIdx = repoMap[pkg.repo]
    else:
      repoIdx = checkedU16(repoMap.len, "repo count")
      repoMap[pkg.repo] = repoIdx
      repoOffsets.addLe32(checkedU32(repoBlob.len, "repo blob offset"))
      repoLens.addLe16(checkedU16(pkg.repo.len, "repo length"))
      repoBlob.add(pkg.repo)
    repoIndices.addLe16(repoIdx)
    flags.add(char(if pkg.installed: 1 else: 0))
    let bucketKey = uint8(ord(lowered[0]))
    buckets[int(bucketKey)].add(uint32(emittedCount))
    emittedCount.inc()

  var runningOffset = 0
  for bucketIdx in 0 ..< BucketCount:
    bucketOffsets.addLe32(uint32(runningOffset))
    bucketLens.addLe32(uint32(buckets[bucketIdx].len))
    for id in buckets[bucketIdx]:
      bucketIds.addUint32Value(id)
    runningOffset += buckets[bucketIdx].len

  let sections = @[
    SectionPayload(name: SectionNames[ssNameOffsets], data: nameOffsets),
    SectionPayload(name: SectionNames[ssNameLens], data: nameLens),
    SectionPayload(name: SectionNames[ssNameBlob], data: nameBlob),
    SectionPayload(name: SectionNames[ssLowerOffsets], data: lowerOffsets),
    SectionPayload(name: SectionNames[ssLowerLens], data: lowerLens),
    SectionPayload(name: SectionNames[ssLowerBlob], data: lowerBlob),
    SectionPayload(name: SectionNames[ssVersionOffsets], data: verOffsets),
    SectionPayload(name: SectionNames[ssVersionLens], data: verLens),
    SectionPayload(name: SectionNames[ssVersionBlob], data: verBlob),
    SectionPayload(name: SectionNames[ssRepoIndices], data: repoIndices),
    SectionPayload(name: SectionNames[ssFlags], data: flags),
    SectionPayload(name: SectionNames[ssRepoOffsets], data: repoOffsets),
    SectionPayload(name: SectionNames[ssRepoLens], data: repoLens),
    SectionPayload(name: SectionNames[ssRepoBlob], data: repoBlob),
    SectionPayload(name: SectionNames[ssBucketOffsets], data: bucketOffsets),
    SectionPayload(name: SectionNames[ssBucketLens], data: bucketLens),
    SectionPayload(name: SectionNames[ssBucketIds], data: bucketIds),
  ]

  createDir(parentDir(outPath))
  let stream = newFileStream(outPath, fmWrite)
  if stream.isNil:
    raise newException(IOError, "failed to open index for writing: " & outPath)
  defer:
    stream.close()

  var header = newStringOfCap(SourceIndexHeaderBytes.int)
  header.add(SourceIndexMagic)
  header.addLe32(SourceIndexVersion)
  header.addLe32(uint32(ord(source)))
  header.addLe32(checkedU32(emittedCount, "package count"))
  header.addLe32(checkedU32(repoMap.len, "repo count"))
  header.addLe32(checkedU32(sections.len, "section count"))
  header.addLe32(SourceIndexHeaderBytes)
  header.addLe32(0'u32)
  stream.write(header)

  let directoryBytes = sections.len * (SectionNameBytes + 8 + 8)
  var currentOffset = SourceIndexHeaderBytes.int + directoryBytes
  for section in sections:
    var nameField = section.name
    if nameField.len > SectionNameBytes:
      raise newException(ValueError, "section name too long: " & section.name)
    nameField.setLen(SectionNameBytes)
    stream.write(nameField)
    var entry = ""
    entry.addLe64(uint64(currentOffset))
    entry.addLe64(uint64(section.data.len))
    stream.write(entry)
    currentOffset += section.data.len

  for section in sections:
    if section.data.len > 0:
      stream.write(section.data)

  result = SourceIndexStats(
    path: outPath,
    source: source,
    packageCount: emittedCount,
    repoCount: repoMap.len,
    fileSize: getFileSize(outPath).int,
  )

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
  if version != SourceIndexVersion.int:
    result.error = "unsupported source index version: " & $version
    return

  let sourceRaw = readU32Bytes(data, 8)
  if sourceRaw > high(IndexedSourceKind).ord:
    result.error = "invalid source index kind"
    return

  result.source = IndexedSourceKind(sourceRaw)
  result.packageCount = readU32Bytes(data, 12)
  result.repoCount = readU32Bytes(data, 16)
  result.sectionCount = readU32Bytes(data, 20)
  let headerBytes = readU32Bytes(data, 24)

  if headerBytes != SourceIndexHeaderBytes.int:
    result.error = "unexpected header byte size"
    return

  let directoryBytes = result.sectionCount * (SectionNameBytes + 8 + 8)
  if mapped.size < headerBytes + directoryBytes:
    result.error = "section directory truncated"
    return

  let directoryStart = headerBytes
  var seenSections = initTable[SourceSectionId, bool]()
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

  for section in SourceSectionId:
    if not seenSections.hasKey(section):
      result.error = "missing required section: " & SectionNames[section]
      return

  result.valid = true

proc openSourceIndex*(path: string): SourceIndexView =
  let validated = validateSourceIndex(path)
  if not validated.valid:
    raise newException(IOError, "invalid source index '" & path & "': " & validated.error)

  result.path = path
  result.source = validated.source
  result.packageCount = validated.packageCount
  result.repoCount = validated.repoCount
  result.sectionCount = validated.sectionCount
  result.fileSize = validated.fileSize
  result.file = memfiles.open(path, mode = fmRead)
  result.mapped = result.file.mem != nil and result.file.size >= SourceIndexHeaderBytes.int

  let directoryStart = SourceIndexHeaderBytes.int
  let base = cast[ptr UncheckedArray[byte]](result.file.mem)
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

proc openValidatedSourceIndex*(validated: ValidatedSourceIndex): SourceIndexView =
  if not validated.valid:
    raise newException(IOError, "invalid source index '" & validated.path & "': " & validated.error)
  openSourceIndex(validated.path)
