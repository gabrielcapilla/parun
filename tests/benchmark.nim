import std/[times, monotimes, strformat]
import ../src/types
import ../src/state
import ../src/simd

type
  BenchmarkResult* = object
    name*: string
    totalTimeMs*: float64
    throughput*: float64
    memoryMiB*: float64
    iterations*: int

  BenchmarkSuite* = object
    results*: seq[BenchmarkResult]
    datasetSizes*: seq[int]

func `$`*(r: BenchmarkResult): string =
  fmt"{r.name}: {r.totalTimeMs:.3}ms, {r.throughput:.0f} ops/s, {r.memoryMiB:.3f} MiB, {r.iterations} iterations"

proc generatePackageDataset*(count: int): (PackageSOA, seq[char]) =
  var soa = PackageSOA(
    hot: PackageHot(locators: newSeq[uint32](count), nameLens: newSeq[uint8](count)),
    cold: PackageCold(
      verLens: newSeq[uint8](count),
      repoIndices: newSeq[uint8](count),
      flags: newSeq[uint8](count),
    ),
  )

  var arena = newSeq[char](count * 50)

  var offset = 0'u32
  for i in 0 ..< count:
    let name = "package_" & $i
    let ver = "1.0." & $(i mod 100)

    soa.hot.locators[i] = offset
    soa.hot.nameLens[i] = uint8(name.len)
    soa.cold.verLens[i] = uint8(ver.len)
    soa.cold.repoIndices[i] = uint8(i mod 255)
    soa.cold.flags[i] = uint8(i mod 2)

    copyMem(addr arena[offset], unsafeAddr name[0], name.len)
    offset += uint32(name.len)

    copyMem(addr arena[offset], unsafeAddr ver[0], ver.len)
    offset += uint32(ver.len)

  return (soa, arena)

proc benchmarkFilterIndices*(
    soa: PackageSOA, arena: seq[char], iterations: int
): BenchmarkResult =
  var state = AppState(
    soa: soa,
    textArena: arena,
    repos: newSeq[string](255),
    repoArena: newSeq[char](0),
    repoLens: newSeq[uint8](255),
    repoOffsets: newSeq[uint16](0),
  )

  var results = newSeq[int32](10_000)
  let queries = @["package", "lib", "tool", "util", "app"]

  let t0 = getMonoTime()

  for iter in 0 ..< iterations:
    let query = queries[iter mod queries.len]
    filterIndices(state, query, results)

  let t1 = getMonoTime()
  let totalMs = (t1 - t0).inMilliseconds.float64

  BenchmarkResult(
    name: "Filter Indices",
    totalTimeMs: totalMs,
    throughput: float64(iterations) / (totalMs / 1000.0),
    memoryMiB: 0.0,
    iterations: iterations,
  )

proc benchmarkSimdSearch*(
    soa: PackageSOA, arena: seq[char], iterations: int
): BenchmarkResult =
  let ctx = prepareSearchContext("package")
  var totalScore = 0

  let t0 = getMonoTime()

  for iter in 0 ..< iterations:
    for i in 0 ..< soa.hot.locators.len:
      let offset = int(soa.hot.locators[i])
      let namePtr = cast[ptr char](unsafeAddr arena[offset])
      totalScore += scorePackageSimd(namePtr, int(soa.hot.nameLens[i]), ctx)

  let t1 = getMonoTime()
  let totalMs = (t1 - t0).inMilliseconds.float64

  BenchmarkResult(
    name: "SIMD Search",
    totalTimeMs: totalMs,
    throughput: float64(iterations * soa.hot.locators.len) / (totalMs / 1000.0),
    memoryMiB: 0.0,
    iterations: iterations * soa.hot.locators.len,
  )

proc benchmarkArenaMemory*(iterations: int): BenchmarkResult =
  var arena = initStringArena(64 * 1024)

  let testStrings =
    @[
      "repository", "package", "version", "description", "license", "author", "url",
      "tags",
    ]

  let t0 = getMonoTime()

  for iter in 0 ..< iterations:
    arena.resetArena()
    for s in testStrings:
      discard allocString(arena, s)

  let t1 = getMonoTime()
  let totalMs = (t1 - t0).inMilliseconds.float64

  BenchmarkResult(
    name: "Arena Memory",
    totalTimeMs: totalMs,
    throughput: float64(iterations * testStrings.len) / (totalMs / 1000.0),
    memoryMiB: float64(arena.buffer.len) / (1024.0 * 1024.0),
    iterations: iterations * testStrings.len,
  )

proc runBenchmarkSuite*(): seq[BenchmarkResult] =
  result = @[]
  let sizes = [1_000, 10_000]

  for size in sizes:
    let (soa, arena) = generatePackageDataset(size)

    result.add(benchmarkFilterIndices(soa, arena, 100))
    result.add(benchmarkSimdSearch(soa, arena, 100))

  result.add(benchmarkArenaMemory(1_000))

proc main() =
  let results = runBenchmarkSuite()

  echo "=== Benchmark Results ==="
  for r in results:
    echo $r

when isMainModule:
  main()
