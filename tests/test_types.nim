import unittest
import ../src/core/types

suite "Types - Constants":
  test "Key constants - ASCII values":
    check KeyNull.ord == 0
    check KeyBackspace.ord == 8
    check KeyTab.ord == 9
    check KeyEnter.ord == 13
    check KeyEsc.ord == 27
    check KeySpace.ord == 32
    check KeyBack.ord == 127

  test "Extended key constants":
    check KeyUp.ord == 200
    check KeyDown.ord == 201
    check KeyLeft.ord == 202
    check KeyRight.ord == 203
    check KeyPageUp.ord == 204
    check KeyPageDown.ord == 205
    check KeyHome.ord == 206
    check KeyEnd.ord == 207
    check KeyF1.ord == 210

  test "Control key constants":
    check KeyCtrlA.ord == 1
    check KeyCtrlD.ord == 4
    check KeyCtrlE.ord == 5
    check KeyCtrlN.ord == 14
    check KeyCtrlR.ord == 18
    check KeyCtrlS.ord == 19
    check KeyCtrlU.ord == 21
    check KeyCtrlY.ord == 25

  test "ANSI color constants":
    check AnsiReset == "\e[0m"
    check AnsiBold == "\e[1m"
    check ColorRepo == "\e[95m"
    check ColorPkg == "\e[97m"
    check ColorVer == "\e[92m"
    check ColorState == "\e[36m"
    check ColorSel == "\e[93m"
    check ColorPrompt == "\e[36m"
    check ColorHighlightBg == "\e[48;5;235m"

  test "Mode constants":
    check ColorModeLocal == "\e[1;32m"
    check ColorModeAur == "\e[1;35m"
    check ColorModeNimble == "\e[1;33m"
    check ColorModeReview == "\e[1;33m"

  test "Size constants":
    check DetailsCacheLimit == 16
    check BatchSize == 64 * 1024

  test "Enums de modo":
    check ModeLocal.ord == 0
    check ModeAUR.ord == 1

  test "Enums de datasource":
    check SourceSystem.ord == 0
    check SourceNimble.ord == 1

  test "Enums de mensajes":
    check MsgInput.ord == 0
    check MsgTick.ord == 1
    check MsgSearchResults.ord == 2
    check MsgDetailsLoaded.ord == 3
    check MsgError.ord == 4

suite "Types - Initialization":
  test "PackageHot initialized":
    var hot = PackageHot(locators: newSeq[uint32](), nameLens: newSeq[uint8]())
    check hot.locators.len == 0
    check hot.nameLens.len == 0

  test "PackageCold initialized":
    var cold = PackageCold(
      verLens: newSeq[uint8](), repoIndices: newSeq[uint8](), flags: newSeq[uint8]()
    )
    check cold.verLens.len == 0
    check cold.repoIndices.len == 0
    check cold.flags.len == 0

  test "PackageSOA initialized":
    var soa = PackageSOA(
      hot: PackageHot(locators: @[], nameLens: @[]),
      cold: PackageCold(verLens: @[], repoIndices: @[], flags: @[]),
    )
    check soa.hot.locators.len == 0
    check soa.cold.verLens.len == 0

  test "ResultsBuffer initialized":
    var buf: ResultsBuffer
    check buf.count == 0

  test "StringArena initialized":
    var arena = StringArena(buffer: newSeq[char](1024), capacity: 1024, offset: 0)
    check arena.capacity == 1024
    check arena.offset == 0

  test "PackageDB initialized":
    var db = PackageDB(
      soa: PackageSOA(
        hot: PackageHot(locators: @[], nameLens: @[]),
        cold: PackageCold(verLens: @[], repoIndices: @[], flags: @[]),
      ),
      textArena: @[],
      repos: @[],
      repoArena: @[],
      repoLens: @[],
      repoOffsets: @[],
      isLoaded: false,
    )
    check db.isLoaded == false
    check db.repos.len == 0

suite "Types - Memory Layout":
  test "PackageHot - SoA layout":
    var hot = PackageHot()
    hot.locators = @[uint32(100), uint32(200), uint32(300)]
    hot.nameLens = @[uint8(3), uint8(4), uint8(5)]

    # Verify array separation
    check hot.locators.len == hot.nameLens.len
    check addr(hot.locators[0]) != addr(hot.nameLens[0])

  test "PackageCold - SoA layout":
    var cold = PackageCold()
    cold.verLens = @[uint8(3), uint8(4)]
    cold.repoIndices = @[uint8(0), uint8(1)]
    cold.flags = @[uint8(1), uint8(0)]

    check cold.verLens.len == cold.repoIndices.len
    check cold.repoIndices.len == cold.flags.len

  test "StringArena - contiguous buffer":
    var arena = StringArena(buffer: newSeq[char](1024), capacity: 1024, offset: 0)
    arena.offset = 100

    check arena.offset < arena.capacity

  test "ResultsBuffer - fixed size in stack":
    var buf: ResultsBuffer
    # Verify that indices and scores have fixed size
    check buf.indices.len == 2000
    check buf.scores.len == 2000
