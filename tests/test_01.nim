import std/[unittest, strutils, tables, random, monotimes, times, strformat]
import ../src/[types, pkgManager]

proc createMockPageBuilder(): PageBuilder =
  result.pages = @[]
  result.currentPage = newStringOfCap(PageSize)
  result.pkgs = newSeqOfCap[CompactPackage](1000)
  result.repoMap = initTable[string, uint16]()
  result.repos = @[]

suite "Stress Tests":
  setup:
    var pb = createMockPageBuilder()
    var installedMap = initTable[string, string]()
    randomize()

  test "Fuzzing: Malformed and Dangerous Inputs":
    let dangerousInputs =
      @[
        "",
        "   ",
        "core",
        "core bash",
        "core bash 5.0",
        "/ / /",
        "core bash 5.0 [installed] extra garbage",
        repeat("a", 1000),
        "\e[31mcore\e[0m bash 5.0",
        "core bash 5.0 \0 nullbyte",
        "core bash " & repeat("9", 500),
        cast[string](@['\xFF', '\xFE', '\x00']),
      ]

    var errors = 0
    for input in dangerousInputs:
      try:
        parsePacmanOutput(input, pb, installedMap)
      except CatchableError:
        echo fmt"[Fuzz Failure] Crashed on input: {input.escape}"
        errors.inc()

    check errors == 0

  test "Fuzzing: Random Generation (Monkey Testing)":
    const Iterations = 50_000
    var validParses = 0
    for i in 1 .. Iterations:
      let len = rand(1 .. 300)
      var s = newString(len)
      for j in 0 ..< len:
        s[j] = char(rand(0 .. 255))
      try:
        parsePacmanOutput(s, pb, installedMap)
        if pb.pkgs.len > validParses:
          validParses = pb.pkgs.len
      except CatchableError as e:
        echo fmt"Crash con input aleatorio #{i}: {e.msg}"
        fail()

    check true

  test "Stress: Memory Stability (1 Million pkgs)":
    const NumPackages = 1_000_000
    const BatchSize = 1000
    let tStart = getMonoTime()
    let repos = ["core", "extra", "community", "multilib", "aur_super_long_repo_name"]
    var processed = 0

    while processed < NumPackages:
      let r = repos[rand(0 .. 4)]
      let n = "pkg-name-" & $processed
      let v = "1.0." & $rand(0 .. 99) & "-1"
      let line = fmt"{r} {n} {v}"

      parsePacmanOutput(line, pb, installedMap)
      processed.inc()

      if processed mod BatchSize == 0:
        if pb.currentPage.len > 0:
          pb.pages.add(pb.currentPage)
          pb.currentPage = newStringOfCap(PageSize)

    let tEnd = getMonoTime()
    let dur = (tEnd - tStart).inMilliseconds

    check pb.pkgs.len == NumPackages
    check pb.pages.len > 0

    if dur > 3000:
      echo fmt"  [Warn] Low performance: {dur}ms"
    else:
      echo fmt"  [Perf] Ok performance ({dur}ms)"

  test "Logic: Page Mapping Verification":
    let longName = repeat("x", 250)
    let line = fmt"core {longName} 1.0"
    let bytesPerPkg = 255
    let pkgsToFill = (PageSize div bytesPerPkg) + 5

    for i in 0 ..< pkgsToFill:
      parsePacmanOutput(line, pb, installedMap)

    check pb.pages.len >= 1
    let pkgOnNextPageIdx = (PageSize div bytesPerPkg) + 1
    if pkgOnNextPageIdx < pb.pkgs.len:
      let p = pb.pkgs[pkgOnNextPageIdx]
      check p.pageOffset < 300
