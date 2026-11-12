import std/strutils
import ../src/catalog/detail_cache
import ../src/catalog/model
import ../src/sources/worker_cache

proc main() =
  var cache = initDetailCache()
  doAssert detailCacheCapacityBytes(cache) == 0

  let small = repeat("package metadata\n", 32)
  detailCachePut(cache, 7, small)
  doAssert detailCacheHas(cache, 7)
  doAssert detailCacheGet(cache, 7) == small
  doAssert detailCacheUsedBytes(cache) > 0
  doAssert detailCacheCapacityBytes(cache) < DetailsCacheByteBudget

  let larger = repeat("0123456789abcdef\n", 180)
  detailCachePut(cache, 8, larger)
  doAssert detailCacheHas(cache, 8)
  doAssert detailCacheGet(cache, 8) == larger
  doAssert detailCacheCapacityBytes(cache) < DetailsCacheByteBudget

  let boundedPayload = repeat("0123456789abcdef", 512)
  for i in 0 ..< DetailsCacheLimit + 16:
    detailCachePut(cache, int32(100 + i), boundedPayload)
  doAssert detailCacheLen(cache) <= DetailsCacheLimit
  doAssert detailCacheCapacityBytes(cache) <= DetailsCacheByteBudget

  var workerCache = initDetailsCache()
  for i in 0 ..< WorkerDetailsCacheLimit + 16:
    putDetailsCache(workerCache, "package-" & $i, boundedPayload)
  doAssert workerCache.count <= WorkerDetailsCacheLimit
  doAssert detailsCacheBytes(workerCache) <= detailsCacheBudgetBytes()

  echo "test_detail_cache: PASS"

when isMainModule:
  main()
