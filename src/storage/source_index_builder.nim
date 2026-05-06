## Immutable source index builder.
##
## Notes:
## - Converts package records into deterministic sectioned `.prix` artifacts.
## - Keeps hot fields and cold fields, including repository URLs, separated for
##   runtime locality.
## - Opportunistically applies compact encodings (24-bit words, 8-bit repo ids,
##   compressed cold blobs) when safe.
import std/[os, streams, strutils, tables, times]
import source_index_core, source_index_codec

proc initSourceIndexBuilder*(source: IndexedSourceKind): SourceIndexBuilder =
  ## Initializes empty builder state for one source kind.
  result.source = source
  result.repoMap = initOrderedTable[string, uint16]()
  result.usesWideWords = false
  for i in 0 ..< BucketCount:
    result.buckets[i] = @[]

proc addPackageToIndex*(
    builder: var SourceIndexBuilder,
    name, version, repo: string,
    installed: bool,
    url: string = "",
) =
  ## Adds one package record to builder buffers.
  ##
  ## `url` is optional for sources whose detail backend does not need upstream
  ## metadata. Nimble indexes pass the package repository URL here so later
  ## detail lookup can resolve the remote `.nimble` manifest directly from the
  ## mapped `.prix` data.
  if name.len == 0:
    return

  if name.len > high(uint16).int:
    raise newException(ValueError, "package name too long for index: " & name)
  if version.len > high(uint16).int:
    raise newException(ValueError, "package version too long for index: " & name)
  if url.len > high(uint16).int:
    raise newException(ValueError, "package url too long for index: " & name)

  builder.nameOffsets.addLe32(checkedU32(builder.nameBlob.len, "name blob offset"))
  builder.nameLens.addLe16(checkedU16(name.len, "name length"))
  builder.nameBlob.add(name)

  builder.verOffsets.addLe32(checkedU32(builder.verBlob.len, "version blob offset"))
  builder.verLens.addLe16(checkedU16(version.len, "version length"))
  builder.verBlob.add(version)

  builder.urlOffsets.addLe32(checkedU32(builder.urlBlob.len, "url blob offset"))
  builder.urlLens.addLe16(checkedU16(url.len, "url length"))
  builder.urlBlob.add(url)

  var repoIdx: uint16
  if builder.repoMap.hasKey(repo):
    repoIdx = builder.repoMap[repo]
  else:
    repoIdx = checkedU16(builder.repoMap.len, "repo count")
    builder.repoMap[repo] = repoIdx
    builder.repoOffsets.addLe32(checkedU32(builder.repoBlob.len, "repo blob offset"))
    builder.repoLens.addLe16(checkedU16(repo.len, "repo length"))
    builder.repoBlob.add(repo)

  builder.repoIndices.addLe16(repoIdx)
  builder.flags.add(char(if installed: 1 else: 0))

  let bucketKey = uint8(ord(name[0].toLowerAscii))
  builder.buckets[int(bucketKey)].add(uint32(builder.emittedCount))
  if builder.emittedCount > PackedWord24Limit.int:
    builder.usesWideWords = true
  if builder.nameBlob.len > PackedWord24Limit.int or
      builder.verBlob.len > PackedWord24Limit.int or
      builder.repoBlob.len > PackedWord24Limit.int or
      builder.urlBlob.len > PackedWord24Limit.int:
    builder.usesWideWords = true
  builder.emittedCount.inc()

proc finishSourceIndex*(
    builder: var SourceIndexBuilder, outPath: string
): SourceIndexStats =
  ## Finalizes and writes `.prix` file atomically.
  var bucketOffsets, bucketLens, bucketIds: string
  var runningOffset = 0
  for bucketIdx in 0 ..< BucketCount:
    bucketOffsets.addLe32(uint32(runningOffset))
    bucketLens.addLe32(uint32(builder.buckets[bucketIdx].len))
    for id in builder.buckets[bucketIdx]:
      bucketIds.addUint32Value(id)
    runningOffset += builder.buckets[bucketIdx].len

  let useWideWords =
    builder.usesWideWords or (not canPackWords24(builder.nameOffsets)) or
    (not canPackWords24(builder.lowerOffsets)) or
    (not canPackWords24(builder.verOffsets)) or (
      not canPackWords24(builder.repoOffsets)
    ) or (not canPackWords24(builder.urlOffsets)) or
    (not canPackWords24(bucketOffsets)) or (not canPackWords24(bucketLens)) or
    (not canPackWords24(bucketIds))

  let nameOffsetsData =
    if useWideWords:
      builder.nameOffsets
    else:
      packWords24(builder.nameOffsets)
  let lowerOffsetsData =
    if useWideWords:
      builder.lowerOffsets
    else:
      packWords24(builder.lowerOffsets)
  let verOffsetsData =
    if useWideWords:
      builder.verOffsets
    else:
      packWords24(builder.verOffsets)
  let repoOffsetsData =
    if useWideWords:
      builder.repoOffsets
    else:
      packWords24(builder.repoOffsets)
  let urlOffsetsData =
    if useWideWords:
      builder.urlOffsets
    else:
      packWords24(builder.urlOffsets)
  let bucketOffsetsData =
    if useWideWords:
      bucketOffsets
    else:
      packWords24(bucketOffsets)
  let bucketLensData =
    if useWideWords:
      bucketLens
    else:
      packWords24(bucketLens)
  let bucketIdsData =
    if useWideWords:
      bucketIds
    else:
      packWords24(bucketIds)
  let useNarrowRepoIdx = canPackU8FromU16(builder.repoIndices)
  let repoIndicesData =
    if useNarrowRepoIdx:
      packU8FromU16(builder.repoIndices)
    else:
      builder.repoIndices
  let encodedVerBlob = encodeColdBlob(builder.verBlob)
  let encodedRepoBlob = encodeColdBlob(builder.repoBlob)
  let useCompressedVerBlob =
    encodedVerBlob.len > 0 and encodedVerBlob.len < builder.verBlob.len
  let useCompressedRepoBlob =
    encodedRepoBlob.len > 0 and encodedRepoBlob.len < builder.repoBlob.len
  let verBlobData = if useCompressedVerBlob: encodedVerBlob else: builder.verBlob
  let repoBlobData = if useCompressedRepoBlob: encodedRepoBlob else: builder.repoBlob

  let sections =
    @[
      SectionPayload(name: SectionNames[ssNameOffsets], data: nameOffsetsData),
      SectionPayload(name: SectionNames[ssNameLens], data: builder.nameLens),
      SectionPayload(name: SectionNames[ssNameBlob], data: builder.nameBlob),
      SectionPayload(name: SectionNames[ssLowerOffsets], data: lowerOffsetsData),
      SectionPayload(name: SectionNames[ssLowerLens], data: builder.lowerLens),
      SectionPayload(name: SectionNames[ssLowerBlob], data: builder.lowerBlob),
      SectionPayload(name: SectionNames[ssVersionOffsets], data: verOffsetsData),
      SectionPayload(name: SectionNames[ssVersionLens], data: builder.verLens),
      SectionPayload(name: SectionNames[ssVersionBlob], data: verBlobData),
      SectionPayload(name: SectionNames[ssRepoIndices], data: repoIndicesData),
      SectionPayload(name: SectionNames[ssFlags], data: builder.flags),
      SectionPayload(name: SectionNames[ssRepoOffsets], data: repoOffsetsData),
      SectionPayload(name: SectionNames[ssRepoLens], data: builder.repoLens),
      SectionPayload(name: SectionNames[ssRepoBlob], data: repoBlobData),
      SectionPayload(name: SectionNames[ssUrlOffsets], data: urlOffsetsData),
      SectionPayload(name: SectionNames[ssUrlLens], data: builder.urlLens),
      SectionPayload(name: SectionNames[ssUrlBlob], data: builder.urlBlob),
      SectionPayload(name: SectionNames[ssBucketOffsets], data: bucketOffsetsData),
      SectionPayload(name: SectionNames[ssBucketLens], data: bucketLensData),
      SectionPayload(name: SectionNames[ssBucketIds], data: bucketIdsData),
    ]

  createDir(parentDir(outPath))
  let millis = int64(epochTime() * 1000.0)
  let tempOutPath =
    outPath & ".build." & $getCurrentProcessId() & "." & $millis & ".tmp"
  let stream = newFileStream(tempOutPath, fmWrite)
  if stream.isNil:
    raise newException(IOError, "failed to open index for writing: " & outPath)
  defer:
    stream.close()

  var header = newStringOfCap(SourceIndexHeaderBytes.int)
  header.add(SourceIndexMagic)
  header.addLe32(SourceIndexVersion)
  header.addLe32(uint32(ord(builder.source)))
  header.addLe32(checkedU32(builder.emittedCount, "package count"))
  header.addLe32(checkedU32(builder.repoMap.len, "repo count"))
  header.addLe32(checkedU32(sections.len, "section count"))
  header.addLe32(SourceIndexHeaderBytes)
  var flags = 0'u32
  if useWideWords:
    flags = flags or HeaderFlagWideWords
  if useNarrowRepoIdx:
    flags = flags or HeaderFlagNarrowRepoIdx
  if useCompressedVerBlob:
    flags = flags or HeaderFlagVerBlobCompressed
  if useCompressedRepoBlob:
    flags = flags or HeaderFlagRepoBlobCompressed
  header.addLe32(flags)
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

  try:
    moveFile(tempOutPath, outPath)
  except CatchableError:
    if fileExists(outPath):
      removeFile(outPath)
    moveFile(tempOutPath, outPath)

  result = SourceIndexStats(
    path: outPath,
    source: builder.source,
    packageCount: builder.emittedCount,
    repoCount: builder.repoMap.len,
    fileSize: getFileSize(outPath).int,
  )

proc buildSourceIndex*(
    source: IndexedSourceKind,
    packages: openArray[IndexedPackageRecord],
    outPath: string,
): SourceIndexStats =
  ## Convenience helper: build index from an in-memory package slice.
  ## This helper preserves name/version/repository/installed state. Call
  ## `addPackageToIndex` directly when constructing indexes that must persist
  ## per-package URLs.
  var builder = initSourceIndexBuilder(source)
  for pkg in packages:
    builder.addPackageToIndex(pkg.name, pkg.version, pkg.repo, pkg.installed)
  builder.finishSourceIndex(outPath)
