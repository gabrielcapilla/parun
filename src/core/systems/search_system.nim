import std/[strutils, bitops]
import ../types
import ../../storage/indexes
import ../../utils/simd

proc filterIndices*(
    query: string,
    view: ptr SourceIndexView,
    results: var seq[int32],
) =
  ## Filtering System (Hot Path).
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
        if isInstalled(view, i):
          results.add(int32(i))
    else:
      results.setLen(totalPkgs)
      for i in 0 ..< totalPkgs:
        results[i] = int32(i)
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

    let i =
      if hasBucket:
        bucketIdAt(view, candidatePos)
      else:
        candidatePos

    if filterInstalled and not isInstalled(view, i):
      continue

    let namePtr = lowerNamePtr(view, i)
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
  ## Filters the visible list to show only selected items.
  results.setLen(0)
  for i, word in selectionBits:
    if word == 0:
      continue
    for bit in 0 .. 63:
      if testBit(word, bit):
        let realIdx = i * 64 + bit
        if realIdx < totalPkgs:
          results.add(int32(realIdx))
