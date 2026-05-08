import std/[os, times, strutils]
import ../src/storage/indexes

type Faults = object
  minor: uint64
  major: uint64

proc readFaults(): Faults =
  let stat = readFile("/proc/self/stat")
  let closeParen = stat.rfind(')')
  if closeParen < 0 or closeParen + 2 >= stat.len:
    return
  let fields = stat[(closeParen + 2) .. ^1].splitWhitespace()
  if fields.len > 9:
    result.minor = parseUInt(fields[7])
    result.major = parseUInt(fields[9])

proc main() =
  if paramCount() < 1:
    quit("usage: bench_source_index_open INDEX_PATH [ITERATIONS]", 2)

  let path = paramStr(1)
  let iterations =
    if paramCount() >= 2:
      parseInt(paramStr(2))
    else:
      1000

  if iterations <= 0:
    quit("iterations must be positive", 2)

  var touched = 0
  let beforeFaults = readFaults()
  let started = epochTime()

  for _ in 0 ..< iterations:
    var view = openSourceIndex(path)
    prefaultHotSections(addr view)
    if view.packageCount > 0:
      let bucket = bucketRange(addr view, uint8(ord('a')))
      if bucket.len > 0:
        touched += bucketIdAt(addr view, bucket.a)
      touched += getNameLen(addr view, 0)
    close(view)

  let elapsedUs = int64((epochTime() - started) * 1_000_000.0)
  let afterFaults = readFaults()
  let perOpenNs = (elapsedUs * 1000) div iterations

  echo "iterations=", iterations
  echo "elapsed_us=", elapsedUs
  echo "per_open_ns=", perOpenNs
  echo "minor_faults=", afterFaults.minor - beforeFaults.minor
  echo "major_faults=", afterFaults.major - beforeFaults.major
  echo "touched=", touched

main()
