import std/[strutils, bitops]
import ../types
import ../../utils/simd

proc filterIndices*(
    query: string,
    soa: PackageSOA,
    textArena: openArray[char],
    results: var seq[int32],
) =
  ## Filtering System (Hot Path).
  let count = results.len
  results.setLen(0)
  results.setLen(count)

  let effective = getEffectiveQuery(query)
  let cleanQuery = effective.strip()
  let totalPkgs = soa.hot.locators.len
  let filterInstalled = query.startsWith("installed/") or query.startsWith("i/")

  if cleanQuery.len == 0:
    if filterInstalled:
      results.setLen(0)
      for i in 0 ..< totalPkgs:
        if isInstalled(soa, i):
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

  if textArena.len == 0:
    return
  let arenaBase = cast[int](unsafeAddr textArena[0])

  for i in 0 ..< totalPkgs:
    if buf.count >= 2000:
      break

    if filterInstalled and not isInstalled(soa, i):
      continue

    let offset = int(soa.hot.locators[i])
    let namePtr = cast[ptr char](arenaBase + offset)

    let s = scorePackageSimd(namePtr, int(soa.hot.nameLens[i]), ctx)
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
