import std/[os, sets, unittest]
import ../src/catalog/model
import ../src/catalog/state
import ../src/catalog/layout
import ../src/catalog/search
import ../src/index/indexes
import ../src/app/input
import ../src/ui/renderer
import ./helpers

proc readLe32(data: string, pos: int): uint32 =
  uint32(ord(data[pos])) or (uint32(ord(data[pos + 1])) shl 8) or
    (uint32(ord(data[pos + 2])) shl 16) or (uint32(ord(data[pos + 3])) shl 24)

proc readLe64(data: string, pos: int): uint64 =
  for i in 0 ..< 8:
    result = result or (uint64(ord(data[pos + i])) shl (i * 8))

proc writeLe64(data: var string, pos: int, value: uint64) =
  for i in 0 ..< 8:
    data[pos + i] = char((value shr (i * 8)) and 0xFF)

proc sectionRange(data, wanted: string): tuple[offset, size: int] =
  let count = int(readLe32(data, 20))
  for idx in 0 ..< count:
    let base = SourceIndexHeaderBytes.int + idx * (SectionNameBytes + 8 + 8)
    var name = ""
    for i in 0 ..< SectionNameBytes:
      if data[base + i] == '\x00':
        break
      name.add(data[base + i])
    if name == wanted:
      return (
        int(readLe64(data, base + SectionNameBytes)),
        int(readLe64(data, base + SectionNameBytes + 8)),
      )
  raise newException(ValueError, "missing test section: " & wanted)

proc makeIndex(dir, stem: string, packageCount = 256): string =
  createDir(dir)
  var builder = initSourceIndexBuilder(iskSystem)
  for i in 0 ..< packageCount:
    addPackageToIndex(
      builder,
      name = "pkg-" & $i,
      version = "1.0.0",
      repo = "core",
      installed = (i mod 2) == 0,
      url = "https://example.invalid/packages",
      detail = if i == 0: "Repository     : nimble\nName           : pkg-0\n" else: "",
    )
  result = dir / (stem & ".prix")
  discard finishSourceIndex(builder, result)

proc cleanDir(dir: string) =
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    if kind == pcFile:
      removeFile(path)
  removeDir(dir)

proc lazyOpenFails(path: string): bool =
  try:
    var view = openSourceIndexLazy(path)
    view.close()
  except CatchableError:
    return true
  false

proc copyWithSuffix(base, suffix: string): string =
  result = base & suffix
  copyFile(base, result)

proc foldText(checksum: var uint64, value: string) =
  for ch in value:
    checksum = (checksum xor uint64(uint8(ch))) * 1099511628211'u64

proc sweepChecksum(view: ptr SourceIndexView, query: string): uint64 =
  var results = newSeq[int32](packageCount(view))
  var visibleAll = false
  var visibleAllCount: int32 = 0
  discard filterIndices(query, view, results, visibleAll, visibleAllCount)
  result = 1469598103934665603'u64
  let count =
    if visibleAll:
      int(visibleAllCount)
    else:
      results.len
  for row in 0 ..< count:
    let idx =
      if visibleAll:
        row
      else:
        int(results[row])
    result = (result xor uint64(idx)) * 1099511628211'u64
    result.foldText(copyName(view, idx))
    result.foldText(copyVersion(view, idx))
    result.foldText(copyRepo(view, idx))
    result.foldText(copyUrl(view, idx))

suite "source index validation and lazy opening":
  test "selection toggles stable repo/name identities":
    let dir = getTempDir() / ("parun-source-index-selection-" & $getCurrentProcessId())
    defer:
      cleanDir(dir)
    let path = makeIndex(dir, "selection", 1)
    var state = newState(SlotSystem, false, {SlotSystem}, false)
    state.sourceViews[SlotSystem] = openSourceIndex(path)
    defer:
      close(state.sourceViews[SlotSystem])
    let view = addr state.sourceViews[SlotSystem]

    state.toggleSelection(view, 0)
    check state.selectedPackages.len == 1
    check state.isSelectedPackage(view, 0)
    state.toggleSelection(view, 0)
    check state.selectedPackages.len == 0
    check not state.isSelectedPackage(view, 0)

    state.selectedPackages.incl("core/pkg-0")
    state.cursor = 8
    state.scroll = 4
    processInput(state, KeyCtrlS, 10)
    check state.viewingSelection
    check state.visibleCount() == 1
    check state.visibleIdxAt(0) == 0
    check state.cursor == 0
    check state.scroll == 0
    processInput(state, KeyCtrlS, 10)
    check not state.viewingSelection
    check state.visibleAll
    check state.visibleCount() == 1
    processInput(state, 'p', 10)
    check state.searchBuffer == "p"
    check not state.visibleAll
    check state.visibleCount() == 1
    check state.visibleIdxAt(0) == 0

  test "lazy proofs preserve eager records and are idempotent":
    let dir = getTempDir() / ("parun-source-index-lazy-" & $getCurrentProcessId())
    defer:
      cleanDir(dir)
    let path = makeIndex(dir, "valid")

    let shallow = validateSourceIndex(path, deep = false)
    let deep = validateSourceIndex(path)
    check shallow.valid
    check not shallow.deep
    check deep.valid
    check deep.deep

    var eager = openSourceIndex(path)
    var lazy = openSourceIndexLazy(path)
    check valid(addr eager)
    check valid(addr lazy)
    check not lazy.provenBuckets
    check not lazy.provenVersionMap
    check not lazy.provenRepoMap
    check not lazy.provenUrlMap
    check not lazy.provenDetailMap

    check ensureBucketSections(addr lazy) == ""
    check ensureBucketSections(addr lazy) == ""
    check ensureRepoSections(addr lazy) == ""
    check ensureRepoSections(addr lazy) == ""
    check ensureVersionSections(addr lazy) == ""
    check ensureVersionSections(addr lazy) == ""
    check ensureUrlSections(addr lazy) == ""
    check ensureUrlSections(addr lazy) == ""
    check ensureDetailSections(addr lazy) == ""
    check ensureDetailSections(addr lazy) == ""
    check lazy.provenBuckets
    check lazy.provenVersionMap
    check lazy.provenRepoMap
    check lazy.provenUrlMap
    check lazy.provenDetailMap

    var eagerResults = newSeq[int32](256)
    var lazyResults = newSeq[int32](256)
    for query in ["", "pkg-1", "pkg-127", "zz-no-hit", "installed/pkg"]:
      var eagerAll = false
      var lazyAll = false
      var eagerAllCount: int32 = 0
      var lazyAllCount: int32 = 0
      discard filterIndices(query, addr eager, eagerResults, eagerAll, eagerAllCount)
      discard filterIndices(query, addr lazy, lazyResults, lazyAll, lazyAllCount)
      check eagerAll == lazyAll
      check eagerAllCount == lazyAllCount
      check eagerResults == lazyResults

    for i in [0, 1, 127, 255]:
      check copyName(addr lazy, i) == copyName(addr eager, i)
      check copyVersion(addr lazy, i) == copyVersion(addr eager, i)
      check copyRepo(addr lazy, i) == copyRepo(addr eager, i)
      check copyUrl(addr lazy, i) == copyUrl(addr eager, i)
      check copyDetail(addr lazy, i) == copyDetail(addr eager, i)

    check copyDetail(addr eager, 0) ==
      "Repository     : nimble\nName           : pkg-0\n"
    check copyDetail(addr eager, 1) == ""

    var rendererView = openSourceIndexLazy(path)
    check packageSelectionKey(addr rendererView, 0) == "core/pkg-0"
    check rendererView.provenRepoMap
    var row = ""
    appendRow(row, addr rendererView, 0, 80, false, false)
    check rendererView.provenVersionMap
    close(rendererView)

    for query in ["", "pkg-1", "pkg-127", "zz-no-hit", "installed/pkg"]:
      check sweepChecksum(addr lazy, query) == sweepChecksum(addr eager, query)

    close(lazy)
    close(eager)

  test "shallow and deep open reject bounded corruption corpus":
    let dir = getTempDir() / ("parun-source-index-corrupt-" & $getCurrentProcessId())
    defer:
      cleanDir(dir)
    let base = makeIndex(dir, "base")
    let original = readFile(base)

    let truncated = copyWithSuffix(base, ".truncated")
    writeFile(truncated, original[0 ..< SourceIndexHeaderBytes.int - 1])
    check not validateSourceIndex(truncated, deep = false).valid
    check lazyOpenFails(truncated)

    let unknown = copyWithSuffix(base, ".unknown")
    var unknownData = original
    unknownData[SourceIndexHeaderBytes.int] = 'x'
    writeFile(unknown, unknownData)
    check not validateSourceIndex(unknown, deep = false).valid
    check lazyOpenFails(unknown)

    let unsupportedVersion = copyWithSuffix(base, ".unsupported-version")
    var unsupportedVersionData = original
    writeLe32(unsupportedVersionData, 4, SourceIndexVersion - 1)
    writeFile(unsupportedVersion, unsupportedVersionData)
    check not validateSourceIndex(unsupportedVersion, deep = false).valid
    check lazyOpenFails(unsupportedVersion)

    let outOfBounds = copyWithSuffix(base, ".range")
    var rangeData = original
    writeLe64(
      rangeData,
      SourceIndexHeaderBytes.int + SectionNameBytes,
      uint64(rangeData.len + 1),
    )
    writeFile(outOfBounds, rangeData)
    check not validateSourceIndex(outOfBounds, deep = false).valid
    check lazyOpenFails(outOfBounds)

    let shortSection = copyWithSuffix(base, ".short")
    var shortData = original
    let nameLenBase = SourceIndexHeaderBytes.int + (1 * (SectionNameBytes + 8 + 8))
    writeLe64(shortData, nameLenBase + SectionNameBytes + 8, 1)
    writeFile(shortSection, shortData)
    check not validateSourceIndex(shortSection, deep = false).valid
    check lazyOpenFails(shortSection)

    let duplicate = copyWithSuffix(base, ".duplicate")
    var duplicateData = original
    let firstEntry = SourceIndexHeaderBytes.int
    let secondEntry = firstEntry + SectionNameBytes + 8 + 8
    for i in 0 ..< SectionNameBytes:
      duplicateData[secondEntry + i] = duplicateData[firstEntry + i]
    writeFile(duplicate, duplicateData)
    check not validateSourceIndex(duplicate, deep = false).valid
    check lazyOpenFails(duplicate)

    let badBucket = copyWithSuffix(base, ".bucket")
    var bucketData = original
    let bucketIds = sectionRange(bucketData, "bucket_ids")
    let wordBytes =
      if (readLe32(bucketData, 28) and HeaderFlagWideWords) != 0: 4 else: 3
    for i in 0 ..< wordBytes:
      bucketData[bucketIds.offset + i] = '\xFF'
    writeFile(badBucket, bucketData)
    check validateSourceIndex(badBucket, deep = false).valid
    check not validateSourceIndex(badBucket).valid
    var bucketView = openSourceIndexLazy(badBucket)
    check ensureBucketSections(addr bucketView).len > 0
    check not valid(addr bucketView)
    close(bucketView)

    let flags = readLe32(original, 28)
    if (flags and HeaderFlagVerBlobCompressed) != 0:
      let badCompressed = copyWithSuffix(base, ".compressed")
      var compressedData = original
      let versionBlob = sectionRange(compressedData, "ver_blob")
      writeLe32(
        compressedData, versionBlob.offset + ColdBlobHeaderBytes - PackedWord32Bytes, 0
      )
      writeFile(badCompressed, compressedData)
      check validateSourceIndex(badCompressed, deep = false).valid
      check not validateSourceIndex(badCompressed).valid
      var compressedView = openSourceIndexLazy(badCompressed)
      check ensureVersionSections(addr compressedView).len > 0
      check not valid(addr compressedView)
      close(compressedView)

  test "same-size index replacement advances the source generation":
    let dir = getTempDir() / ("parun-source-index-replace-" & $getCurrentProcessId())
    defer:
      cleanDir(dir)
    let path = makeIndex(dir, "system", 256)
    var state = newState(SlotSystem, false, {SlotSystem}, false)
    state.prepareIndexedSources(dir)
    defer:
      state.closeIndexedSources()

    check valid(state.activeView)
    let originalSize = getFileSize(path)
    let originalGeneration = state.detailGeneration
    let replacementPath = dir / "replacement.prix"
    var replacement = initSourceIndexBuilder(iskSystem)
    for i in 0 ..< 256:
      addPackageToIndex(
        replacement,
        name =
          if i == 0:
            "pkg-X"
          else:
            "pkg-" & $i,
        version = "1.0.0",
        repo = "core",
        installed = (i mod 2) == 0,
        url = "https://example.invalid/packages",
        detail = if i == 0: "Repository     : nimble\nName           : pkg-X\n" else: "",
      )
    discard finishSourceIndex(replacement, replacementPath)
    check getFileSize(replacementPath) == originalSize
    sleep(300)
    moveFile(replacementPath, path)
    sleep(300)
    state.pollIndexUpdates()
    check state.detailGeneration > originalGeneration
    check copyName(state.activeView, 0) == "pkg-X"
