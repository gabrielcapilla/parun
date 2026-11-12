import source_index_codec
import source_index_core
import source_index_runtime
import source_index_validation

proc openSourceIndexLazy*(path: string): SourceIndexView =
  let validated = validateSourceIndex(path, deep = false)
  if not validated.valid:
    raise
      newException(IOError, "invalid source index '" & path & "': " & validated.error)

  mapValidatedSourceIndex(validated, initializeColdMeta = false)

proc proofFailure(view: var SourceIndexView, err: string): string {.inline.} =
  if err.len > 0:
    view.proofError = err
  err

proc ensureBucketSections*(view: var SourceIndexView): string =
  if view.provenBuckets:
    return ""
  let err = proveBucketIds(
    cast[pointer](view.file.mem),
    view.sections[ssBucketOffsets],
    view.sections[ssBucketLens],
    view.sections[ssBucketIds],
    view.packageCount,
    view.wordBytes,
  )
  if err.len > 0:
    return proofFailure(view, err)
  view.provenBuckets = true
  ""

proc ensureBucketSections*(view: ptr SourceIndexView): string =
  if view.isNil:
    return "source index view is nil"
  ensureBucketSections(view[])

proc ensureVersionSections*(view: var SourceIndexView): string =
  if view.provenVersionMap:
    return ""
  if (view.headerFlags and HeaderFlagVerBlobCompressed.int) == 0:
    let err = proveRawMap(
      cast[pointer](view.file.mem),
      view.sections[ssVersionOffsets],
      view.sections[ssVersionLens],
      view.sections[ssVersionBlob],
      view.packageCount,
      view.wordBytes,
      "version",
    )
    if err.len > 0:
      return proofFailure(view, err)
    view.provenVersionMap = true
    return ""
  let base = cast[pointer](view.file.mem)
  let blobErr = validateCompressedBlobSection(
    cast[ptr UncheckedArray[byte]](cast[int](base) + view.sections[ssVersionBlob].offset),
    view.sections[ssVersionBlob].size,
    SectionNames[ssVersionBlob],
  )
  if blobErr.len > 0:
    return proofFailure(view, blobErr)
  let err = proveVersionMap(
    base,
    view.sections[ssVersionOffsets],
    view.sections[ssVersionLens],
    view.sections[ssVersionBlob],
    view.packageCount,
    view.wordBytes,
  )
  if err.len > 0:
    return proofFailure(view, err)
  try:
    view.versionBlobMeta =
      initCompressedBlobMeta(addr view, ssVersionBlob, enabled = true)
  except CatchableError:
    return proofFailure(view, getCurrentExceptionMsg())
  view.provenVersionMap = true
  ""

proc ensureVersionSections*(view: ptr SourceIndexView): string =
  if view.isNil:
    return "source index view is nil"
  ensureVersionSections(view[])

proc ensureRepoSections*(view: var SourceIndexView): string =
  if view.provenRepoMap:
    return ""
  if (view.headerFlags and HeaderFlagRepoBlobCompressed.int) == 0:
    let err = proveRawMap(
      cast[pointer](view.file.mem),
      view.sections[ssRepoOffsets],
      view.sections[ssRepoLens],
      view.sections[ssRepoBlob],
      view.repoCount,
      view.wordBytes,
      "repo",
    )
    if err.len > 0:
      return proofFailure(view, err)
    view.provenRepoMap = true
    return ""
  let base = cast[pointer](view.file.mem)
  let blobErr = validateCompressedBlobSection(
    cast[ptr UncheckedArray[byte]](cast[int](base) + view.sections[ssRepoBlob].offset),
    view.sections[ssRepoBlob].size,
    SectionNames[ssRepoBlob],
  )
  if blobErr.len > 0:
    return proofFailure(view, blobErr)
  let err = proveRepoMap(
    base,
    view.sections[ssRepoOffsets],
    view.sections[ssRepoLens],
    view.sections[ssRepoBlob],
    view.repoCount,
    view.wordBytes,
  )
  if err.len > 0:
    return proofFailure(view, err)
  try:
    view.repoBlobMeta = initCompressedBlobMeta(addr view, ssRepoBlob, enabled = true)
  except CatchableError:
    return proofFailure(view, getCurrentExceptionMsg())
  view.provenRepoMap = true
  ""

proc ensureRepoSections*(view: ptr SourceIndexView): string =
  if view.isNil:
    return "source index view is nil"
  ensureRepoSections(view[])

proc ensureUrlSections*(view: var SourceIndexView): string =
  if view.provenUrlMap:
    return ""
  if view.sections[ssUrlOffsets].size == 0 and view.sections[ssUrlLens].size == 0 and
      view.sections[ssUrlBlob].size == 0:
    view.provenUrlMap = true
    return ""
  let err = proveRawMap(
    cast[pointer](view.file.mem),
    view.sections[ssUrlOffsets],
    view.sections[ssUrlLens],
    view.sections[ssUrlBlob],
    view.packageCount,
    view.wordBytes,
    "url",
  )
  if err.len > 0:
    return proofFailure(view, err)
  view.provenUrlMap = true
  ""

proc ensureUrlSections*(view: ptr SourceIndexView): string =
  if view.isNil:
    return "source index view is nil"
  ensureUrlSections(view[])

proc ensureDetailSections*(view: var SourceIndexView): string =
  if view.provenDetailMap:
    return ""
  if view.sections[ssDetailOffsets].size == 0 and view.sections[ssDetailLens].size == 0 and
      view.sections[ssDetailBlob].size == 0:
    view.provenDetailMap = true
    return ""
  let err = proveRawMap(
    cast[pointer](view.file.mem),
    view.sections[ssDetailOffsets],
    view.sections[ssDetailLens],
    view.sections[ssDetailBlob],
    view.packageCount,
    view.wordBytes,
    "detail",
  )
  if err.len > 0:
    return proofFailure(view, err)
  view.provenDetailMap = true
  ""

proc ensureDetailSections*(view: ptr SourceIndexView): string =
  if view.isNil:
    return "source index view is nil"
  ensureDetailSections(view[])
