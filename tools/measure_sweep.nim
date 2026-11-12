import std/[algorithm, json, os, osproc, parseopt, sequtils, streams, strutils]

type Options = object
  harness: string
  binary: string
  indexDir: string
  output: string
  samples: int
  details: bool
  detailsTrace: bool
  detailsLocal: bool
  detailsNimble: bool

proc parseOptions(): Options =
  result = Options(
    harness: getCurrentDir() / "tools" / "measure_baseline",
    binary: getCurrentDir() / "parun",
    output: getCurrentDir() / "tools" / "output" / "measurement-sweep.json",
    samples: 5,
    details: true,
    detailsTrace: false,
    detailsLocal: false,
    detailsNimble: false,
  )

  var parser = initOptParser()
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdLongOption:
      case parser.key
      of "harness":
        result.harness = parser.val
      of "binary":
        result.binary = parser.val
      of "index-dir":
        result.indexDir = parser.val
      of "output":
        result.output = parser.val
      of "samples":
        result.samples = parseInt(parser.val)
      of "details":
        result.details = true
      of "details-trace":
        result.details = true
        result.detailsTrace = true
      of "details-local":
        result.details = true
        result.detailsLocal = true
      of "no-details":
        result.details = false
      of "details-nimble":
        result.details = true
        result.detailsNimble = true
      else:
        raise newException(ValueError, "unknown option --" & parser.key)
    else:
      raise newException(ValueError, "unexpected argument: " & parser.key)

  if result.samples <= 0:
    raise newException(ValueError, "--samples must be positive")
  if not fileExists(result.harness):
    raise newException(IOError, "measurement harness not found: " & result.harness)
  if not fileExists(result.binary):
    raise newException(IOError, "application binary not found: " & result.binary)
  if result.details and result.indexDir.len == 0:
    raise newException(ValueError, "--index-dir is required for detail measurements")

proc metric(payload: JsonNode, sampleName, metricName: string): int =
  payload["samples"][sampleName][metricName & "_kb"].getInt

proc summarize(values: seq[int]): JsonNode =
  if values.len == 0:
    return newJObject()
  var sorted = values
  sorted.sort()
  %*{
    "min_kb": sorted[0],
    "median_kb": sorted[sorted.len div 2],
    "max_kb": sorted[^1],
    "spread_kb": sorted[^1] - sorted[0],
  }

proc runSample(
    opts: Options, sampleIndex: int, samplePath, perfPath: string
): JsonNode =
  var args = @[
    (if opts.details: "--details-no-animation" else: ""),
    (if opts.details and not opts.detailsTrace: "--details-no-trace" else: ""),
    "--binary=" & opts.binary,
    "--output=" & samplePath,
    "--perf-output=" & perfPath,
  ]
  args = args.filterIt(it.len > 0)
  if opts.indexDir.len > 0:
    args.add("--index-dir=" & opts.indexDir)
  if opts.detailsNimble:
    args.add("--details-nimble")
  if opts.detailsLocal:
    args.add("--details-local")

  let process =
    startProcess(opts.harness, args = args, options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    let tailStart = max(0, output.len - 2000)
    let outputTail =
      if output.len > 0:
        output[tailStart ..^ 1]
      else:
        ""
    raise newException(
      IOError,
      "measurement sample " & $sampleIndex & " failed (exit " & $exitCode & "):\n" &
        outputTail,
    )
  if not fileExists(samplePath):
    raise newException(IOError, "measurement sample did not write: " & samplePath)
  parseJson(readFile(samplePath))

proc main() =
  let opts = parseOptions()
  createDir(parentDir(opts.output))
  var samples = newJArray()
  var idleRss, idlePss, postRss, postPss, reopenRss, reopenPss: seq[int]

  for i in 0 ..< opts.samples:
    let samplePath = opts.output & ".sample." & $i & ".json"
    let perfPath = opts.output & ".sample." & $i & ".perf.json"
    if fileExists(samplePath):
      removeFile(samplePath)
    if fileExists(perfPath):
      removeFile(perfPath)

    let payload = runSample(opts, i + 1, samplePath, perfPath)
    let idleName = if opts.details: "idle" else: "idle_local"
    let postName = if opts.details: "post_details" else: "post_aur"
    let reopenName = if opts.details: "post_cached_reopen" else: "post_nimble"
    idleRss.add(metric(payload, idleName, "rss"))
    idlePss.add(metric(payload, idleName, "pss"))
    postRss.add(metric(payload, postName, "rss"))
    postPss.add(metric(payload, postName, "pss"))
    reopenRss.add(metric(payload, reopenName, "rss"))
    reopenPss.add(metric(payload, reopenName, "pss"))
    samples.add(
      %*{
        "sample": i + 1,
        "idle_rss_kb": idleRss[^1],
        "idle_pss_kb": idlePss[^1],
        "post_rss_kb": postRss[^1],
        "post_pss_kb": postPss[^1],
        "reopen_rss_kb": reopenRss[^1],
        "reopen_pss_kb": reopenPss[^1],
      }
    )

  let result = %*{
    "schema_version": 1,
    "kind": "parun_measurement_sweep",
    "samples_requested": opts.samples,
    "details": opts.details,
    "trace": opts.detailsTrace,
    "source":
      if opts.detailsLocal:
        "local"
      elif opts.detailsNimble:
        "nimble"
      else:
        "aur",
    "binary": absolutePath(opts.binary),
    "harness": absolutePath(opts.harness),
    "index_dir": opts.indexDir,
    "samples": samples,
    "summary": {
      "idle_rss": summarize(idleRss),
      "idle_pss": summarize(idlePss),
      "post_rss": summarize(postRss),
      "post_pss": summarize(postPss),
      "reopen_rss": summarize(reopenRss),
      "reopen_pss": summarize(reopenPss),
    },
  }
  writeFile(opts.output, pretty(result))
  echo pretty(result)

when isMainModule:
  main()
