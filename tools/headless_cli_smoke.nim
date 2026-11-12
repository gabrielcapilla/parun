import std/[json, os, osproc, streams, strutils]

import ../src/index/indexes
import ../tests/helpers

proc run(binary: string, args: seq[string]): tuple[code: int, output: string] =
  let process =
    startProcess(binary, args = args, options = {poUsePath, poStdErrToStdOut})
  let output = process.outputStream.readAll()
  let code = process.waitForExit()
  process.close()
  (code, output)

proc main() =
  var binary = ""
  for arg in commandLineParams():
    if arg.startsWith("--binary="):
      binary = arg[9 ..^ 1]
  if binary.len == 0:
    raise newException(ValueError, "usage: headless_cli_smoke --binary=PATH")

  let root = getTempDir() / ("parun-headless-cli-" & $getCurrentProcessId())
  removeTree(root)
  createDir(root)
  defer:
    removeTree(root)
  let fixture = root / "indexes"
  discard makeNimbleFixture(fixture)

  let success = run(
    binary,
    @[
      "--headless",
      "--nimble",
      "--index-dir=" & fixture,
      "--headless-query=nph",
      "--headless-rounds=1",
    ],
  )
  if success.code != 0:
    raise newException(IOError, "headless success case failed:\n" & success.output)
  let successJson = parseJson(success.output)
  doAssert successJson["kind"].getStr == "parun_headless_search"
  doAssert successJson["package_count"].getInt == 1

  let validIndex =
    run(binary, @["--internal-validate-index=" & fixture / "nimble.prix"])
  if validIndex.code != 0:
    raise newException(IOError, "valid index validation failed:\n" & validIndex.output)
  let validIndexJson = parseJson(validIndex.output)
  doAssert validIndexJson["valid"].getBool

  let unsupportedPath = root / "unsupported.prix"
  var unsupported = readFile(fixture / "nimble.prix")
  writeLe32(unsupported, 4, SourceIndexVersion - 1)
  writeFile(unsupportedPath, unsupported)
  let invalidIndex = run(binary, @["--internal-validate-index=" & unsupportedPath])
  if invalidIndex.code == 0:
    raise newException(IOError, "unsupported index validation unexpectedly succeeded")
  let invalidIndexJson = parseJson(invalidIndex.output)
  doAssert not invalidIndexJson["valid"].getBool
  doAssert "unsupported source index version" in invalidIndexJson["error"].getStr

  let failure = run(
    binary,
    @[
      "--headless",
      "--nimble",
      "--index-dir=" & root / "missing",
      "--headless-query=nph",
      "--headless-rounds=1",
    ],
  )
  if failure.code == 0:
    raise newException(IOError, "headless missing-index case unexpectedly succeeded")
  let failureJson = parseJson(failure.output)
  doAssert failureJson["kind"].getStr == "parun_headless_search"
  doAssert failureJson["status"].getStr == "error"
  echo "headless CLI smoke passed"

when isMainModule:
  main()
