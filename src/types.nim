import std/[sets, tables]

const
  KeyCtrlA* = char(1)
  KeyCtrlB* = char(2)
  KeyCtrlC* = char(3)
  KeyCtrlD* = char(4)
  KeyCtrlE* = char(5)
  KeyCtrlF* = char(6)
  KeyBackspace* = char(8)
  KeyTab* = char(9)
  KeyEnter* = char(13)
  KeyCtrlN* = char(14)
  KeyCtrlR* = char(18)
  KeyCtrlS* = char(19)
  KeyCtrlU* = char(21)
  KeyCtrlY* = char(25)
  KeyEsc* = char(27)
  KeySpace* = char(32)
  KeyBack* = char(127)

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
  ColorModeHybrid* = "\e[1;35m"
  ColorModeNimble* = "\e[1;33m"
  ColorModeReview* = "\e[1;33m"
  ColorVimNormal* = "\e[1;44;97m"
  ColorVimInsert* = "\e[1;42;97m"
  ColorVimCommand* = "\e[1;41;97m"

  PageSize* = 64 * 1024

type
  CompactPackage* = object
    pageIdx*: uint16
    pageOffset*: uint16
    repoIdx*: uint16
    nameLen*: uint8
    flags*: uint8

  SearchMode* = enum
    ModeLocal
    ModeHybrid

  DataSource* = enum
    SourceSystem
    SourceNimble

  InputMode* = enum
    ModeStandard
    ModeVimNormal
    ModeVimInsert
    ModeVimCommand

  MsgKind* = enum
    MsgInput
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
    MsgError

  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgTick:
      discard
    of MsgSearchResults:
      packedPkgs*: seq[CompactPackage]
      pages*: seq[string]
      repos*: seq[string]
      searchId*: int
      isAppend*: bool
      durationMs*: int
    of MsgDetailsLoaded:
      pkgId*: string
      content*: string
    of MsgError:
      errMsg*: string

  AppState* = object
    pkgs*: seq[CompactPackage]

    memoryPages*: seq[string]

    repoList*: seq[string]

    localPkgCount*: int
    localPageCount*: int
    localRepoCount*: int

    visibleIndices*: seq[int32]
    selected*: HashSet[string]

    detailsCache*: Table[string, string]

    cursor*: int
    scroll*: int
    searchBuffer*: string
    searchCursor*: int
    commandBuffer*: string

    searchMode*: SearchMode
    dataSource*: DataSource
    inputMode*: InputMode
    viewingSelection*: bool

    isSearching*: bool
    searchId*: int
    needsRedraw*: bool
    shouldQuit*: bool
    shouldInstall*: bool
    shouldUninstall*: bool
    showDetails*: bool
    justReceivedSearchResults*: bool

    detailScroll*: int

func isInstalled*(p: CompactPackage): bool {.inline.} =
  (p.flags and 1) != 0
