## Hot-path filtering over immutable source indexes.
##
## Notes:
## - Input query is normalized via `getEffectiveQuery`.
## - Empty query uses identity view (`visibleAll=true`) unless `installed/` filter is active.
## - Non-empty query narrows candidates by first-byte bucket before SIMD scoring.
## - Results are capped (`ResultsBuffer` size) and then score-sorted.
import std/[strutils, bitops, sets]
import types
import state_soa
import ../storage/indexes
import ../utils/simd

proc filterIndices*(
    query: string,
    view: ptr SourceIndexView,
    results: var seq[int32],
    visibleAll: var bool,
    visibleAllCount: var int32,
    perf: ptr PerfCounters = nil,
) =
  ## Produces visible package ids for the current query.
  ##
  ## Performance contract:
  ## - avoid heap allocations in the candidate loop
  ## - update perf counters when provided
  if not perf.isNil:
    perf[].hotFilterCalls.inc()
  visibleAll = false
  visibleAllCount = 0
  let count = results.len
  results.setLen(0)
  results.setLen(count)

  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()
  let totalPkgs = packageCount(view)
  let filterInstalled = query.startsWith("installed/") or query.startsWith("i/")

  if cleanQuery.len == 0:
    if filterInstalled:
      results.setLen(0)
      for i in 0 ..< totalPkgs:
        if not perf.isNil:
          perf[].hotInstalledChecks.inc()
        if isInstalled(view, i):
          results.add(int32(i))
    else:
      results = @[]
      visibleAll = true
      visibleAllCount = int32(totalPkgs)
    return

  let ctx = prepareSearchContext(cleanQuery)
  if not ctx.isValid:
    return

  var buf: ResultsBuffer
  buf.count = 0

  if not valid(view):
    return
  let firstToken = ctx.lowerTokens[0]
  let hasBucket =
    firstToken.len > 0 and firstToken[0].ord >= 0 and firstToken[0].ord <= 255
  let candidateRange =
    if hasBucket:
      bucketRange(view, uint8(ord(firstToken[0])))
    else:
      0 ..< totalPkgs

  for candidatePos in candidateRange:
    if buf.count >= 2000:
      break
    if not perf.isNil:
      perf[].hotFilterCandidates.inc()

    let i =
      if hasBucket:
        if not perf.isNil:
          perf[].hotBucketLookups.inc()
        bucketIdAt(view, candidatePos)
      else:
        candidatePos

    if filterInstalled and not isInstalled(view, i):
      if not perf.isNil:
        perf[].hotInstalledChecks.inc()
      continue

    let namePtr = lowerNamePtr(view, i)
    if not perf.isNil:
      perf[].hotScoreCalls.inc()
    let s = scorePackageSimd(namePtr, getLowerLen(view, i), ctx)
    if s > 0:
      buf.indices[buf.count] = int32(i)
      buf.scores[buf.count] = s
      inc(buf.count)

  countingSortResults(buf)

  results.setLen(buf.count)
  for i in 0 ..< buf.count:
    results[i] = buf.indices[i]

proc filterBySelection*(
    selectionBits: openArray[uint64], totalPkgs: int, results: var seq[int32]
) =
  ## Materializes only selected package ids into `results`.
  results.setLen(0)
  for i, word in selectionBits:
    if word == 0:
      continue
    for bit in 0 .. 63:
      if testBit(word, bit):
        let realIdx = i * 64 + bit
        if realIdx < totalPkgs:
          results.add(int32(realIdx))

proc filterBySelection*(
    selectedPackages: HashSet[string],
    view: ptr SourceIndexView,
    results: var seq[int32],
) =
  ## Materializes selected package ids in the active source view.
  results.setLen(0)
  let totalPkgs = packageCount(view)
  for i in 0 ..< totalPkgs:
    if packageSelectionKey(view, i) in selectedPackages:
      results.add(int32(i))
