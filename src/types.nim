import std/[tables, monotimes]

const
  DetailsCacheLimit* = 16
  BatchSize* = 64 * 1024

  KeyNull* = char(0)
  KeyCtrlA* = char(1)
  KeyCtrlB* = char(2)
  KeyCtrlC* = char(3)
  KeyCtrlD* = char(4)
  KeyCtrlE* = char(5)
  KeyCtrlF* = char(6)
  KeyBackspace* = char(8)
  KeyTab* = char(9)
  KeyCtrlJ* = char(10)
  KeyEnter* = char(13)
  KeyCtrlN* = char(14)
  KeyCtrlR* = char(18)
  KeyCtrlS* = char(19)
  KeyCtrlU* = char(21)
  KeyCtrlW* = char(23)
  KeyCtrlY* = char(25)
  KeyCtrlZ* = char(26)
  KeyEsc* = char(27)
  KeySpace* = char(32)
  KeyBack* = char(127)
  KeyCtrlBackspace* = char(28)
  KeyAltBackspace* = char(29)

  KeyDelete* = char(209)
  KeyCtrlLeft* = char(220)
  KeyCtrlRight* = char(221)

  KeyUp* = char(200)
  KeyDown* = char(201)
  KeyLeft* = char(202)
  KeyRight* = char(203)
  KeyPageUp* = char(204)
  KeyPageDown* = char(205)
  KeyHome* = char(206)
  KeyEnd* = char(207)
  KeyDetailUp* = char(208)
  KeyDetailDown* = char(209)
  KeyF1* = char(210)

  AnsiReset* = "\e[0m"
  AnsiBold* = "\e[1m"
  AnsiDim* = "\e[2m"
  ColorRepo* = "\e[95m"
  ColorPkg* = "\e[97m"
  ColorVer* = "\e[92m"
  ColorState* = "\e[36m"
  ColorSel* = "\e[93m"
  ColorPrompt* = "\e[36m"
  ColorHighlightBg* = "\e[48;5;235m"

  ColorModeLocal* = "\e[1;32m"
  ColorModeAur* = "\e[1;35m"
  ColorModeNimble* = "\e[1;33m"
  ColorModeReview* = "\e[1;33m"

type
  SearchMode* = enum
    ModeLocal
    ModeAUR

  DataSource* = enum
    SourceSystem
    SourceNimble

  MsgKind* = enum
    MsgInput
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
    MsgError

  PackageSOA* = object
    locators*: seq[uint32]
    nameLens*: seq[uint8]
    verLens*: seq[uint8]
    repoIndices*: seq[uint8]
    flags*: seq[uint8]

  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgTick:
      discard
    of MsgSearchResults:
      soa*: PackageSOA
      textChunk*: string
      repos*: seq[string]
      searchId*: int
      isAppend*: bool
      durationMs*: int
    of MsgDetailsLoaded:
      pkgIdx*: int32
      content*: string
    of MsgError:
      errMsg*: string

  PackageDB* = object
    soa*: PackageSOA
    textArena*: seq[char]
    repos*: seq[string]
    isLoaded*: bool

  AppState* = object
    soa*: PackageSOA
    textArena*: seq[char]
    repos*: seq[string]

    systemDB*: PackageDB
    aurDB*: PackageDB
    nimbleDB*: PackageDB

    visibleIndices*: seq[int32]
    selectionBits*: seq[uint64]
    detailsCache*: Table[int32, string]

    cursor*: int
    scroll*: int
    searchBuffer*: string
    searchCursor*: int

    searchMode*: SearchMode
    dataSource*: DataSource

    baseSearchMode*: SearchMode
    baseDataSource*: DataSource

    viewingSelection*: bool

    isSearching*: bool
    searchId*: int
    dataSearchId*: int

    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    justReceivedSearchResults*: bool
    statusMessage*: string

    detailScroll*: int

    lastInputTime*: MonoTime
    debouncePending*: bool

func isInstalled*(flags: uint8): bool {.inline.} =
  (flags and 1) != 0
