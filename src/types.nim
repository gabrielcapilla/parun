import std/[sets, tables]

const
  DetailsCacheLimit* = 16
  BlockSize* = 64 * 1024

  KeyNull* = char(0)
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
  ColorModeHybrid* = "\e[1;35m"
  ColorModeNimble* = "\e[1;33m"
  ColorModeReview* = "\e[1;33m"
  ColorVimNormal* = "\e[1;44;97m"
  ColorVimInsert* = "\e[1;42;97m"
  ColorVimCommand* = "\e[1;41;97m"

type
  PackedPackage* = object
    blockIdx*: uint16
    offset*: uint16
    repoIdx*: uint8
    nameLen*: uint8
    verLen*: uint8
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
    MsgInputNew
    MsgTick
    MsgSearchResults
    MsgDetailsLoaded
    MsgError

  Msg* = object
    case kind*: MsgKind
    of MsgInput:
      key*: char
    of MsgInputNew:
      legacyKey*: char
    of MsgTick:
      discard
    of MsgSearchResults:
      pkgs*: seq[PackedPackage]
      textBlock*: string
      repos*: seq[string]
      searchId*: int
      isAppend*: bool
      durationMs*: int
    of MsgDetailsLoaded:
      pkgId*: string
      content*: string
    of MsgError:
      errMsg*: string

  PackageDB* = object
    pkgs*: seq[PackedPackage]
    textBlocks*: seq[string]
    repos*: seq[string]
    isLoaded*: bool

  AppState* = object
    pkgs*: seq[PackedPackage]
    textBlocks*: seq[string]
    repos*: seq[string]

    systemDB*: PackageDB
    nimbleDB*: PackageDB

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

func isInstalled*(p: PackedPackage): bool {.inline.} =
  (p.flags and 1) != 0
